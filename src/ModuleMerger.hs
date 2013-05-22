module ModuleMerger (mergeModules) where
import AST
import Data.List
import Data.Maybe
    
mergeModules :: [(FilePath,Module)] -> Module
mergeModules mods = foldl merge emptyModule mods'
    where mods' = map updateLocation mods

merge :: Module -> Module -> Module
merge mod1 mod2 = Module {
        modName = listToMaybe $ mapMaybe modName [mod1, mod2],
        modImports = [],
        modEntities = modEntities mod1 ++ modEntities mod2,
        modClasses = modClasses mod1 ++ modClasses mod2,
        modEnums = modEnums mod1 ++ modEnums mod2,
        modRoutes = modRoutes mod1 ++ modRoutes mod2
    }

updateLocation :: (FilePath,Module) -> Module
updateLocation (path,mod) = mod {
        modEntities = map (updateEntityLoc path) (modEntities mod),
        modClasses  = map (updateClassLoc path) (modClasses mod)
    } 
    where 
        updateEntityLoc path e = e { entityLoc = updateLoc path (entityLoc e) }
        updateClassLoc path i = i { classLoc = updateLoc path (classLoc i) }
 
updateLoc :: FilePath -> Location -> Location
updateLoc path (Loc _ l c) = Loc path l c


