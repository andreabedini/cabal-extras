{-# LANGUAGE BangPatterns #-}
module CabalIfaceQuery.Main (main) where

import Peura
import Prelude ()

import Control.Applicative ((<**>))
import Data.Version        (showVersion)

import qualified Cabal.Config            as Cbl
import qualified Cabal.Plan              as P
import qualified Data.Map.Strict         as M
import qualified Data.Set                as S
import qualified Data.Text               as T
import qualified Distribution.ModuleName as MN
import qualified Distribution.Package    as C
import qualified Distribution.Parsec     as C
import qualified Options.Applicative     as O

import Paths_cabal_iface_query (version)

import CabalIfaceQuery.GHC

import qualified CabalIfaceQuery.GHC.All as GHC


-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

main :: IO ()
main = runPeu () $ do
    -- options
    opts <- liftIO $ O.execParser optsP'

    -- ghc info, in particular storeDir
    ghcInfo <- getGhcInfo $ optCompiler opts
    cblCfg  <- liftIO Cbl.readConfig
    storeDir <- makeAbsoluteFilePath $ runIdentity $ Cbl.cfgStoreDir cblCfg
    let storeDir' = storeDir </> fromUnrootedFilePath ("ghc-" ++ prettyShow (ghcVersion ghcInfo))
    let globalDir = takeDirectory $ ghcGlobalDb ghcInfo

    -- read plan
    plan <- case optPlan opts of
        Just planPath -> do
            planPath' <- makeAbsolute planPath
            putInfo $ "Reading plan.json: " ++ toFilePath planPath'
            liftIO $ P.decodePlanJson (toFilePath planPath')
        Nothing -> do
            putInfo "Reading plan.json for current project"
            liftIO $ P.findAndDecodePlanJson (P.ProjectRelativeToDir ".")

    -- TODO: check that ghcInfo version and plan one are the same

    dflags <- getDynFlags ghcInfo

    -- read destination directories of units in the plan
    unitDistDirs <- traverse makeAbsoluteFilePath
            [ distDir
            | unit <- M.elems (P.pjUnits plan)
            , P.uType unit == P.UnitTypeLocal
            , distDir <- toList (P.uDistDir unit)
            ]

    -- interface files
    hiFiles <- fmap concat $ for unitDistDirs $ \distDir ->  do
        hiFiles <- globDir1 "build/**/*.hi" distDir
        return $ (,) distDir <$> hiFiles

    -- name cache updater, needed for reading interface files
    ncu <- liftIO makeNameCacheUpdater

    -- For each of .hi file we found, let us see if there are orphans
    modules <- fmap (ordNub  . concat) $ for hiFiles $ \(distDir, hiFile) -> do
        modIface <- liftIO $ easyReadBinIface dflags ncu hiFile
        putInfo $ "Found interface file for " ++ ghcShow dflags (GHC.mi_module modIface)

        let deps = GHC.mi_deps modIface
        let orphs = GHC.dep_orphs deps

        return
            [ (distDir', orph)
            | orph@(GHC.Module unitId _) <- orphs
            , let distDir' = if ghcShow dflags unitId == "main"
                             then Just (distDir </> fromUnrootedFilePath "build")
                             else Nothing
            ]

    for_ modules $ \(mDistDir, GHC.Module unitId md) -> do
        let strUnitId = ghcShow dflags unitId

        let moduleName = MN.fromString (ghcShow dflags md)
        let moduleNamePath' = MN.toFilePath moduleName ++ ".hi"

        case mDistDir of
            Just distDir -> do
                putWarning WModuleWithOrphans $ "Orphans in " ++ ghcShow dflags md ++ " (" ++ strUnitId ++ ")"

                moduleNamePath <- globDir1First ("**/" ++ moduleNamePath') distDir 
                modIface <- liftIO $ easyReadBinIface dflags ncu moduleNamePath

                for_ (GHC.mi_insts modIface) $ \ifClsInst ->
                    when (GHC.isOrphan $ GHC.ifInstOrph ifClsInst) $
                    putWarning WOrphans $ ghcShowIfaceClsInst dflags ifClsInst

            Nothing -> case M.lookup (P.UnitId $ T.pack strUnitId) (P.pjUnits plan) of
                Nothing   -> when (strUnitId `notElem` ["base", "ghc"]) $
                    putWarning WUnknownUnit $ "Cannot find unit info for " ++ strUnitId ++ " " ++ ghcShow dflags md

                Just unit -> do
                    let P.PkgId pname _ = P.uPId unit

                    unless (toCabal pname `S.member` optSkipPackages opts) $ do
                        putWarning WModuleWithOrphans $ "Orphans in " ++ ghcShow dflags md ++ " (" ++ strUnitId ++ ")"

                        distDir <- unitDistDir globalDir storeDir' unit

                        moduleNamePath <- globDir1First ("**/" ++ moduleNamePath') distDir 
                        modIface <- liftIO $ easyReadBinIface dflags ncu moduleNamePath

                        for_ (GHC.mi_insts modIface) $ \ifClsInst ->
                            when (GHC.isOrphan $ GHC.ifInstOrph ifClsInst) $
                            putWarning WOrphans $ ghcShowIfaceClsInst dflags ifClsInst


  where
    optsP' = O.info (optsP <**> O.helper <**> versionP) $ mconcat
        [ O.fullDesc
        , O.progDesc "Query interface files"
        , O.header "cabal-iface-query - all iface belong to us"
        ]

    versionP = O.infoOption (showVersion version)
        $ O.long "version" <> O.help "Show version"

-------------------------------------------------------------------------------
-- Unit extras
-------------------------------------------------------------------------------

unitDistDir
    :: Path Absolute
    -> Path Absolute
    -> P.Unit
    -> Peu r (Path Absolute)
unitDistDir globalDir storeDir unit = case P.uDistDir unit of
    Just dir -> do
        absdir <- makeAbsoluteFilePath dir
        return $ absdir </> fromUnrootedFilePath "build"

    Nothing
        | P.uType unit == P.UnitTypeGlobal -> do
            let P.UnitId unitId = P.uId unit
            return $ storeDir </> fromUnrootedFilePath (T.unpack unitId) </> fromUnrootedFilePath "lib"

        | P.uType unit == P.UnitTypeBuiltin -> do
            let P.UnitId unitId = P.uId unit
            return $ globalDir </> fromUnrootedFilePath (T.unpack unitId)

        | otherwise -> do
            putError $ show unit
            exitFailure

-------------------------------------------------------------------------------
-- Opts
-------------------------------------------------------------------------------

data Opts = Opts
    { optCompiler     :: FilePath
    , optPlan         :: Maybe FsPath
    , optSkipPackages :: Set C.PackageName
    }

optsP :: O.Parser Opts
optsP = Opts
    <$> O.strOption (O.short 'w' <> O.long "with-compiler" <> O.value "ghc" <> O.showDefault <> O.help "Specify compiler to use")
    <*> optional (O.option (O.eitherReader $ return . fromFilePath) (O.short 'p' <> O.long "plan" <> O.metavar "PATH" <> O.help "Use plan.json provided"))
    <*> fmap S.fromList (many (O.option (O.eitherReader C.eitherParsec) $ mconcat
        [ O.short 'e'
        , O.long "exclude"
        , O.metavar "PKGNAME..."
        , O.help "Don't report following packages"
        ]))

-------------------------------------------------------------------------------
-- Warnings
-------------------------------------------------------------------------------

data W
    = WOrphans
    | WModuleWithOrphans
    | WUnknownUnit
    | WMissingIfaceFile

instance Warning W where
    warningToFlag WOrphans             = "orphans"
    warningToFlag WModuleWithOrphans   = "module-with-orphans"
    warningToFlag WUnknownUnit         = "unknown-unit"
    warningToFlag WMissingIfaceFile    = "missing-iface-file"