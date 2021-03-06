{-# LANGUAGE OverloadedStrings #-}

module Luna.Pass.UnitCompilation.ClassProcessing where

import Luna.Prelude hiding (String, s, new, Constructor, Destructor, cons)
import           OCI.Pass         (SubPass, Pass)
import qualified OCI.Pass         as Pass
import qualified OCI.Pass.Manager as Pass
import qualified Luna.IR.Expr     as Term
import OCI.IR.Combinators
import Luna.Builtin.Data.Class    as Class
import Luna.Builtin.Data.Module   as Module
import Luna.Builtin.Data.Function (compile, WithDocumentation (..), documentation, documentedItem)
import Luna.IR
import Control.Monad.State.Dependent
import Control.Monad.Raise
import Luna.Pass.Data.UniqueNameGen
import Luna.Pass.Data.ExprRoots
import Data.TypeDesc
import Data.Text32 (Text32)
import qualified Luna.Pass.UnitCompilation.RecordProcessing as RecordProcessing
import qualified Luna.Pass.UnitCompilation.MethodProcessing as MethodProcessing
import qualified Luna.Pass.Transform.Desugaring.RemoveGrouped  as RemoveGrouped

import           Data.Map (Map)
import qualified Data.Map as Map

data ClassProcessing
type instance Abstract   ClassProcessing = ClassProcessing
type instance Pass.Inputs     Net   ClassProcessing = '[AnyExpr, AnyExprLink]
type instance Pass.Inputs     Layer ClassProcessing = '[AnyExpr // Model, AnyExpr // Succs, AnyExpr // Type, AnyExprLink // Model]
type instance Pass.Inputs     Attr  ClassProcessing = '[]
type instance Pass.Inputs     Event ClassProcessing = '[]

type instance Pass.Outputs    Net   ClassProcessing = '[AnyExpr, AnyExprLink]
type instance Pass.Outputs    Layer ClassProcessing = '[AnyExpr // Model, AnyExpr // Type, AnyExprLink // Model, AnyExpr // Succs]
type instance Pass.Outputs    Attr  ClassProcessing = '[]
type instance Pass.Outputs    Event ClassProcessing = '[New // AnyExpr, Delete // AnyExpr, Delete // AnyExprLink, New // AnyExprLink, OnDeepDelete // AnyExpr]

type instance Pass.Preserves        ClassProcessing = '[]

cutDoc :: (MonadPassManager m, MonadIO m) => Expr Draft -> SubPass ClassProcessing m (Expr Draft, Maybe Text32)
cutDoc e = matchExpr e $ \case
    Documented d a -> (,Just d) . fst <$> (cutDoc =<< source a)
    Marked     _ a -> cutDoc =<< source a
    _              -> return (e, Nothing)

processClass :: (MonadPassManager m, MonadIO m) => Name -> Imports -> Expr ClsASG -> m Class
processClass modName imports root = do
    setAttr (getTypeDesc @ExprRoots) $ ExprRoots [unsafeGeneralize root]
    Pass.eval' RemoveGrouped.runRemoveGrouped
    (className, paramNames, records, methods) <- Pass.eval' @ClassProcessing $ do
        resolveToplevelFields root
        Term (Term.ClsASG native name ps cs ds) <- readTerm root
        params <- mapM source ps
        paramNames <- forM params $ \p -> matchExpr p $ \case
            Var n -> return n
            _     -> error "Unexpected class parameter type"
        decls <- mapM source ds
        resolvedDecls <- fmap catMaybes $ forM decls $ \decl -> do
            (d, doc) <- cutDoc decl
            matchExpr d $ \case
                ASGRootedFunction n r -> do
                    n'   <- source n
                    name <- matchExpr n' $ \(Var n) -> return n
                    return $ Just (name, doc, r)
                _                     -> return $ Nothing
        conses <- mapM source cs
        resolvedConses <- fmap catMaybes $ forM conses $ \cons -> matchExpr cons $ \case
            RecASG n _ -> return $ Just (n, unsafeGeneralize cons)
            _          -> return Nothing
        return (name, paramNames, resolvedConses, resolvedDecls)
    compiledRecords <- mapM (RecordProcessing.processRecord className paramNames . snd) records
    getters         <- fmap (fmap $ WithDocumentation (Just "Field getter.") . Right) $ case records of
        [(_, r)] -> RecordProcessing.generateGetters className paramNames r
        _        -> return def
    let recordsMap = Map.fromList $ zip (fst <$> records) compiledRecords
        bareClass  = Class recordsMap getters
        imps       = imports & importedClasses . at className ?~ WithDocumentation Nothing bareClass
    methodMap <- MethodProcessing.processMethods modName imps className paramNames (fst <$> records) methods
    return $ Class recordsMap (Map.union methodMap getters)

resolveToplevelFields :: (MonadPassManager m, MonadIO m) => Expr ClsASG -> Pass ClassProcessing m
resolveToplevelFields cls = do
    Term (Term.ClsASG native name _ cs _) <- readTerm cls
    conses <- mapM source cs
    (fields, records) <- fmap (partitionEithers . catMaybes) $ forM conses $ \r -> matchExpr r $ \case
        RecASG{}   -> return $ Just $ Right r
        FieldASG{} -> return $ Just $ Left  r
        _          -> return $ Nothing
    when (null records && not native) $ do
        mapM delete cs
        record <- recASG name fields
        rl     <- link (unsafeRelayout record) cls
        modifyExprTerm cls $ wrapped . termClsASG_conss .~ [rl]
