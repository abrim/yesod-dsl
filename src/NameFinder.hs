module NameFinder (findNames) where
import AST
import Data.List


findNames :: Module -> [(String,[Location])]
findNames db 
    | checkNames nameGroups = nameGroups
    | otherwise = []
    where
        entityNames  = [(entityLoc e, entityName e) | e <- dbEntities db ]
        classNames   = [(classLoc i, className i) | i <- dbClasses db ]
        enumNames    = [(enumLoc e, enumName e) | e <- dbEnums db ]
        entityFieldNames = [(entityLoc e, entityName e ++ "." ++ fieldName f)
                           | e <- dbEntities db, f <- entityFields e ]
        classFieldNames = [(classLoc i, className i ++ "." ++ fieldName f)
                           | i <- dbClasses db, f <- classFields i ]
        enumValueNames = [(enumLoc e, enumName e ++ "." ++ v) 
                         | e <- dbEnums db, v <- enumValues e ]
        allNames     = entityNames ++ classNames ++ enumNames ++ entityFieldNames ++ classFieldNames


        sameNameOrd (_,n1) (_,n2) = compare n1 n2
        sortedNames = sortBy sameNameOrd allNames

        sameName (_,n1) (_,n2) = n1 == n2
        groupedNames = groupBy sameName sortedNames

        factorName :: [(Location,String)] -> (String,[Location])
        factorName (all@((_,name):rest)) = (name, [l | (l,_) <- all ])
        nameGroups = map factorName groupedNames

checkNames :: [(String,[Location])] -> Bool
checkNames nameGroups
    | null duplicates = True
    | otherwise = error $ "Duplicate names:\n"
                        ++ (unlines $ map formatDuplicate duplicates)

    where
        formatDuplicate :: (String, [Location]) -> String
        formatDuplicate (name, locs) = name ++ " : " ++ show locs

        duplicates = [ (n, locs) | (n, locs) <- nameGroups, length locs > 1 ]
