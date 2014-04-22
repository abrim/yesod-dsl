
module Validation.State (validate) where

import AST
import Control.Monad.State
import Data.Maybe (isNothing)
import qualified Data.Map as Map
import qualified Data.List as L
type Info = String



data VState = VState {
    stEnv :: Map.Map String [VId],
    stScopePath :: [String],
    stErrors :: [String],
    stHandlerType :: Maybe HandlerType,
    stInsideFor :: Bool
}

initialState :: VState
initialState = VState Map.empty [] [] Nothing False

data VId = VId Int VIdType deriving(Eq)
data VIdType = VEnum EnumType
         | VClass  Class
         | VEntity Entity
         | VDefine Define
         | VField Field
         | VUnique Unique
         | VRoute Route
         | VHandler Handler
         | VParam 
         | VForParam InputFieldRef
         | VReserved
         deriving (Eq,Show)

instance Show VId where
    show (VId s _) = show s
instance Ord VId where
    compare (VId s1 _) (VId s2 _) = compare s1 s2

type Validation = State VState ()



vError :: String -> Validation
vError err = do
    path <- gets stScopePath
    modify $ \st -> st { stErrors = stErrors st ++ [err ++ " in " ++ (show path)] }

withHandler :: HandlerType -> Validation -> Validation
withHandler ht f = do
    modify $ \st -> st { stHandlerType = Just ht }
    f
    modify $ \st -> st { stHandlerType = Nothing }

withScope :: String -> Validation -> Validation
withScope path f = do
    modify $ \st -> st { stScopePath = path:stScopePath st }
    f
    modify $ \st -> let newScope = length (stScopePath st) - 1 in st {
            stScopePath = tail $ stScopePath st,
            stEnv = Map.filter (not . null) $ 
                        Map.map (filter (\(VId s _) -> s <= newScope)) $
                            stEnv st
        }

declare :: Int -> String -> VIdType -> Validation
declare scope name id = do
    st <- get
    let e = stEnv st
    let newId = [VId scope id]
    case Map.lookup name e of
        Just ((VId s t):_) -> do
            if s == scope
                then vError $ "Identifier '" ++ name 
                     ++ "' already declared : " ++ show t ++ ". New declaration" 
                else put $ st { stEnv = Map.adjust (L.sort . (newId++)) name e }
        Nothing -> put $ st { stEnv = Map.insert name newId e }
       
declareGlobal :: String -> VIdType -> Validation        
declareGlobal = declare 0

declareLocal :: String -> VIdType -> Validation
declareLocal name id = do
    scopePath <- gets stScopePath
    declare (length scopePath) name id

withLookup :: String -> (VIdType -> Validation) -> Validation
withLookup name f = do
    env <- gets stEnv
    path <- gets stScopePath
    case Map.lookup name env of
        Just ((VId _ t):_) -> f t
        Nothing -> err path
    where err path = vError $ "Reference to an undeclared identifier '" 
                          ++ name ++ "'" 

ensureReserved :: String -> Validation
ensureReserved name = withLookup name $ \idt -> case idt of 
    VReserved -> return ()
    _ -> vError $ "Reference to an incompatible type"

withLookupField :: String -> (Field -> Validation) -> Validation
withLookupField name f = do
    withLookup name $ \idt -> case idt of
        (VField t) -> f t
        _ -> vError $ "Reference to an incompatible type " ++ show idt 
                     ++ " (expected field) "

withLookupEntity :: String -> (Entity -> Validation) -> Validation
withLookupEntity name f =do
    withLookup name $ \idt -> case idt of
        (VEntity t) -> f t
        _ -> vError $ "Reference to an incompatible type " ++ show idt 
                     ++ " (expected entity)"

    
withLookupEnum :: String -> (EnumType -> Validation) -> Validation
withLookupEnum name f = do
    withLookup name $ \idt -> case idt of
        (VEnum t) -> f t
        _ -> vError $ "Reference to an incompatible type " ++ show idt 
                     ++ " (expected enum)"


validate :: Module -> [String]
validate m = stErrors $ execState (validate' m) initialState

validate' :: Module -> Validation
validate' m = do
    forM_ (modEnums m) $ \e -> declareGlobal (enumName e) (VEnum e)
    forM_ (modClasses m) $ \c -> declareGlobal (className c) (VClass c)
    forM_ (modEntities m) $ \e -> declareGlobal (entityName e) (VEntity e)
    forM_ (modClasses m) vClass
    forM_ (modEntities m) vEntity
    forM_ (modDefines m) vDefine
    forM_ (modRoutes m) vRoute
    return ()

vClass :: Class -> Validation
vClass c = do
    withScope ("class " ++ (className c) ++ " in " ++ (show (classLoc c))) $ do
        forM_ (classFields c) vField
        forM_ (classUniques c) $ vUnique (className c) 

vEntity :: Entity -> Validation
vEntity e = do
    withScope ("entity " ++ (entityName e) ++ " in "++(show $ entityLoc e)) $do
        forM_ (entityFields e) vField
        forM_ (entityUniques e) $ vUnique (entityName e)


vField :: Field -> Validation
vField f = do
    declareLocal (fieldName f) (VField f)
    withScope ("field " ++ fieldName f) $ case fieldContent f of
        EntityField en -> vEntityRef en
        EnumField en -> vEnumRef en
        _ -> return ()

vUnique :: String -> Unique -> Validation
vUnique prefix u = do
    declareGlobal (prefix ++ uniqueName u) (VUnique u)
    withScope ("unique " ++ uniqueName u) $
        forM_ (uniqueFields u) $ \fn -> withLookupField fn $ \f -> return ()

vDefine :: Define -> Validation
vDefine d = do
    declareGlobal (defineName d) (VDefine d)
    withScope ("define " ++ defineName d ++ " in "++(show $ defineLoc d))  $ do
        forM_ (defineParams d) $ \dp -> declareLocal dp VParam
        case defineContent d of
            (DefineSubQuery sq) -> vSelectQuery sq
    
vRoute :: Route -> Validation
vRoute r = do
    declareGlobal (show $ routePath r) (VRoute r)
    withScope ("route " ++ (show $ routePath r) ++ " in " ++ (show $ routeLoc r)) $ do
        forM_ [ n | (n,_) <- zip [1..] $ routePathParams r ] 
            $ \n -> declareLocal ("$" ++ show n) VReserved
        forM_ (routeHandlers r) vHandler
    
vHandler :: Handler -> Validation
vHandler h = do
    declareLocal (show $ handlerType h) (VHandler h)
    withScope ("handler " ++ (show $ handlerType h))  $ do
        case dropWhile notReturn (handlerParams h) of
            (r:(_:_)) -> vError $ "return must be the last statement"
            _ -> return ()
        withHandler (handlerType h) $
            forM_ (handlerParams h) vHandlerParam
    where
        notReturn (Return _) = False
        notReturn _ = True    

vHandlerParam :: HandlerParam -> Validation
vHandlerParam Public = declareLocal "public;" VReserved
vHandlerParam DefaultFilterSort = declareLocal "default-filter-sort;" VReserved
vHandlerParam (Select sq) = do
    declareLocal "select;" VReserved
    vSelectQuery sq
vHandlerParam (Require sq) = do
    let (en,vn) = sqFrom sq
    withLookupEntity en $ \e -> declareLocal vn (VEntity e)
    forM_ (sqJoins sq) vJoin
    case sqWhere sq of 
        Just e -> do    
            withScope  "where expression" $ vBoolExpr e
        Nothing -> return ()    

vHandlerParam (IfFilter (vn,joins,e,useFlag)) = do
    withScope "if param" $ do
        declareLocal vn VReserved
        forM_ joins vJoin
        vBoolExpr e
vHandlerParam (DeleteFrom en vn me) = do
    withScope "delete from" $ do
        withLookupEntity en $ \e -> declareLocal vn (VEntity e)
        case me of
            Just e -> vBoolExpr e
            Nothing -> return ()
vHandlerParam (Update en ifr mifs) = do
    withScope "update" $ do
        withLookupEntity en $ \e -> do
            vInputFieldRef ifr
            case mifs of
                Just ifs -> forM_ ifs $ \(fn,ifr) -> do
                    declareLocal fn VReserved
                    case L.find (\f -> fieldName f == fn) (entityFields e) of
                        Just f' -> return ()
                        Nothing -> vError $ "Reference to undeclared field '"
                                           ++ fn ++ "' in entity " ++ en
                Nothing -> return ()

vHandlerParam (Return ofrs) = do
    declareLocal "return statement" VReserved
    withScope "return" $ 
        forM_ ofrs  vOutputField


vHandlerParam (GetById en ifr vn) = do
    withLookupEntity en $ \e -> do
        declareLocal ("local variable " ++ vn) (VEntity e)
        withScope "get" $ do
            vInputFieldRef ifr
            return ()

vHandlerParam (Insert en mfs mbv) = do
    case mbv of
        Just vn -> declareLocal ("local variable " ++ vn) VReserved
        Nothing -> return ()
    withScope "insert" $ do
        withLookupEntity en $ \e -> do
            case mfs of
                Just ifs -> do
                    forM_ [ ifr | (_,ifr) <- ifs] $ vInputFieldRef
                    case [ fieldName f | f <- entityFields e, (not . fieldOptional) f, isNothing (fieldDefault f) ] L.\\ 
                            [ fn | (fn,_) <- ifs ] of
                        fs@(_:_) -> vError $ "Missing required fields without default value: " ++ (show fs)
                        _ -> return ()    
                    forM_ ifs $ \(fn,_) -> do
                        declareLocal fn VReserved
                        case L.find (\f -> fieldName f == fn) (entityFields e) of
                            Just f' -> return ()
                            Nothing -> vError $ "Reference to undeclared field '"
                                               ++ fn ++ "' in entity " ++ en
                Nothing -> return ()
vHandlerParam (For vn ifr ps) = withScope ("for " ++ vn) $ do
        declareLocal ("local variable " ++ vn) VReserved
        oldForState <- gets stInsideFor
        modify $ \st -> st { stInsideFor = True }
        forM_ ps vHandlerParam
        modify $ \st -> st { stInsideFor = oldForState }
vHandlerParam (Call _ ifrs) = do
    forM_ ifrs vInputFieldRef
    
vSelectQuery :: SelectQuery -> Validation
vSelectQuery sq = do
    let (en,vn) = sqFrom sq
    withLookupEntity en $ \e -> declareLocal vn (VEntity e)
    forM_ (sqJoins sq) vJoin
    case sqWhere sq of 
        Just e -> do    
            withScope  "where expression" $ vBoolExpr e
        Nothing -> return ()    
    forM_ (sqFields sq) vSelectField
    forM_ (sqOrderBy sq) $ \(fr,_) -> vFieldRef fr


vOutputField :: (ParamName, OutputFieldRef) -> Validation
vOutputField (pn,ofr) = do
    declareLocal ("return field " ++ pn) VReserved
    case ofr of
        OutputFieldLocalParam vn -> ensureReserved ("local variable " ++ vn)
        _ -> return ()

vInputFieldRef :: InputFieldRef -> Validation
vInputFieldRef ifr = case ifr of
    InputFieldPathParam n -> withLookup ("$" ++ show n) $ \_ -> return ()
    InputFieldLocalParam vn -> withLookup ("local variable " ++ vn) $ \ _ -> return()
    InputFieldLocalParamField vn fn -> withLookupEntity ("local variable " ++ vn) $ ensureField vn fn
    _ -> return ()

vJoin :: Join -> Validation
vJoin j = do
    path <- gets stScopePath
    withLookupEntity (joinEntity j) $ \e -> declareLocal (joinAlias j) 
                                                         (VEntity e)
    case joinExpr j of
        Just e -> do
            withScope "join expression" $ vBoolExpr e
        Nothing -> if joinType j /= CrossJoin
            then vError $ "Missing join expression"
            else return () 
     
vEntityRef :: EntityName -> Validation
vEntityRef en = withLookupEntity en $ \e -> return ()

vParamRef :: ParamName -> Validation
vParamRef pn = withLookup pn $ \idt -> case idt of
    VParam -> return ()
    _ -> vError $ "Reference to an incompatible type " ++ show idt 
             ++ " (expected parameter)"


vEnumRef :: EnumName -> Validation
vEnumRef en = withLookupEnum en $ \e -> return ()

vBoolExpr :: BoolExpr -> Validation
vBoolExpr (AndExpr e1 e2) = do
    vBoolExpr e1
    vBoolExpr e2
vBoolExpr (OrExpr e1 e2) = do
    vBoolExpr e1
    vBoolExpr e2
vBoolExpr (NotExpr e) = do
    vBoolExpr e
vBoolExpr (BinOpExpr ve1 op ve2) = do
    vValExpr ve1
    vValExpr ve2
     
    return ()

ensureFieldWith :: (Field -> Validation) -> String -> String -> Entity -> Validation
ensureFieldWith vFunc vn fn e = do
    case L.find (\f -> fieldName f == fn) $ entityFields e of
        Just f -> vFunc f
        Nothing -> vError $ "Entity " ++ entityName e ++ " referenced by "
                           ++ vn ++ "." ++ fn 
                           ++ " does not have the field " ++ fn
ensureField :: String -> String -> Entity -> Validation
ensureField = ensureFieldWith (\_ -> return ())
                           

ensureEnumValue :: String -> EnumType -> Validation
ensureEnumValue vn e = do
    case L.find (== vn) $ enumValues e of
        Just f -> return ()
        Nothing -> vError $ "Enum " ++ enumName e 
                           ++ " does not have the value " ++ vn

                           
vFieldRef :: FieldRef -> Validation
vFieldRef (FieldRefId vn) = vEntityRef vn 
vFieldRef (FieldRefNormal vn fn) = withLookupEntity vn $ ensureField vn fn 
vFieldRef (FieldRefRequest fn) = do
    ht <- gets stHandlerType
    case ht of
        Just GetHandler -> vError $ "Reference to request param 'request." ++ fn ++ "' not allowed in GET handler"
        _ -> return ()
vFieldRef (FieldRefEnum en vn) = withLookupEnum en $ ensureEnumValue vn
vFieldRef (FieldRefNamedLocalParam vn) = ensureReserved ("local variable " ++ vn)
vFieldRef _ = return ()

vSelectField :: SelectField -> Validation
vSelectField (SelectAllFields vn) = do
    withLookupEntity vn $ \e -> do 
        forM_ (entityFields e) $ \f -> 
            declareLocal ("select result field : " ++ fieldName f) VReserved

vSelectField (SelectField vn fn man) = do
    case man of
        Just an -> declareLocal ("select result field : " ++ an) VReserved 
        _ -> declareLocal ("select result field : " ++ fn) VReserved
    withLookupEntity vn $ ensureFieldWith notInternal vn fn
        where notInternal f = if fieldInternal f 
                then vError $ "Select cannot return the internal field '" ++ vn ++ "." ++ fn ++ "'"
                else return ()
                
vSelectField (SelectIdField vn man) = do
   case man of
        Just an -> declareLocal ("select result field : " ++ an) VReserved 
        _ -> declareLocal ("select result field : id") VReserved
   vEntityRef vn     
vSelectField (SelectParamField vn pn man) = do
    case man of
        Just an -> declareLocal ("select result field : " ++ an) VReserved
        _ -> declareLocal ("select result field : " ++ pn) VReserved
    vEntityRef vn
    vParamRef pn
vSelectField (SelectValExpr ve an) = do
    vValExpr ve
    declareLocal ("select result field : " ++ an) VReserved

vValExpr :: ValExpr -> Validation
vValExpr ve = case ve of
    FieldExpr fr -> vFieldRef fr
    ConstExpr _ -> return ()
    ConcatManyExpr ves -> forM_ ves vValExpr    
    ValBinOpExpr ve1 _ ve2 -> do
        vValExpr ve1
        vValExpr ve2
    RandomExpr -> return ()
    FloorExpr ve -> vValExpr ve
    CeilingExpr ve -> vValExpr ve
    ExtractExpr fn ve -> do
        if not $ fn `elem` ["century", "day", "decade", "dow", "doy", "epoch",
                            "hour", "isodow", "microseconds", 
                            "millennium", "milliseconds", "minute", "month",
                            "quarter", "second", "timezone", 
                            "timezone_hour", "timezone_minute",
                            "week", "year" ]
            then vError $ "Unknown subfield '" ++ fn ++ "' to extract" 
            else return ()
        vValExpr ve
    SubQueryExpr sq -> do
        withScope "sub-select" $ do
            let (en,vn) = sqFrom sq
            withLookupEntity en $ \e -> declareLocal vn (VEntity e)
            forM_ (sqJoins sq) vJoin 
            case sqFields sq of
                [sf] -> vSelectField sf
                _ -> vError $ "Sub-select must return exactly one field"
         
            case sqWhere sq of 
                Just e -> withScope "where expression" $ vBoolExpr e
                Nothing -> return ()
    ApplyExpr _ _ -> return ()
