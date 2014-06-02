{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module YesodDsl.Generator.Interface where
import YesodDsl.AST
import Data.Maybe
import qualified Data.Text as T
import Data.List
import Text.Shakespeare.Text hiding (toText)
import Data.String.Utils (rstrip)
import YesodDsl.Generator.Models
import YesodDsl.Generator.Common
import YesodDsl.Generator.Esqueleto

validationFieldCheck :: Entity -> Field -> FunctionName -> String
validationFieldCheck e f func = rstrip $ T.unpack $(codegenFile "codegen/validation-field.cg")

validationEntityCheck :: Entity -> FunctionName -> String
validationEntityCheck e func = rstrip $ T.unpack $(codegenFile "codegen/validation-entity.cg")
    where fieldRef f = "(" ++ (lowerFirst . entityName) e ++ upperFirst f ++ " v)"

validationEntity :: Entity -> String
validationEntity e = T.unpack $(codegenFile "codegen/validation-entity-header.cg")
                   ++ (intercalate ",\n " $ [ validationFieldCheck e f func
                                          | f <- entityFields e,
                                            func <- fieldChecks f])
                   ++ (intercalate ",\n " $ [ validationEntityCheck e func |
                                              func <- entityChecks e ])
                   ++ (T.unpack $(codegenFile "codegen/validation-entity-footer.cg"))


validationFieldFunction :: (Field, FunctionName) -> String
validationFieldFunction (f,func) = T.unpack $(codegenFile "codegen/validation-function-field.cg")

validationEntityFunction :: (Entity, FunctionName) -> String
validationEntityFunction (e, func) = T.unpack $(codegenFile "codegen/validation-function-entity.cg")
    

lookupFieldType :: Module -> EntityName -> FieldName -> String
lookupFieldType m en fn = hsFieldType (fromJust $ lookupField m en fn)

handlerCall :: (FunctionName, [TypeName]) -> String
handlerCall (fn,ptns) = T.unpack $(codegenFile "codegen/call-type-signature.cg")
    where paramTypes = concatMap (++" -> ") ptns

interface :: Module -> [Context] -> String
interface m ctxs= T.unpack $(codegenFile "codegen/interface-header.cg")
             ++ (concatMap validationFieldFunction $ 
                    nubBy (\(_,f1) (_,f2) -> f1 == f2)
                    [(f,func) | e <- modEntities m,
                             f <- entityFields e,
                             func <- fieldChecks f ])
             ++ (concatMap validationEntityFunction $ 
                   [ (e, func) |e <- modEntities m,   func <- entityChecks e ])
             ++ (concatMap handlerCall $ concatMap ctxCalls ctxs)
             ++ (concatMap validationEntity (modEntities m))

