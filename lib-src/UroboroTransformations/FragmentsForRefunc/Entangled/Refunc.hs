module UroboroTransformations.FragmentsForRefunc.Entangled.Refunc where

import Uroboro.Tree

import qualified UroboroTransformations.CoDataDefsDisj.Refunc as CoDataDefsDisjR

import UroboroTransformations.Util
import UroboroTransformations.Util.HelperFuns

import Data.List(nubBy, groupBy)
import Data.Maybe(fromJust)
import Control.Arrow
import Control.Monad(liftM)
import Control.Monad.State.Lazy
import Control.Monad.Trans.Class(lift)
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Writer.Lazy

data ExtractFlag = NormalExtract | IgnoreLeftExtract
                 deriving (Eq)

extractWithFlag :: ExtractFlag -> PT -> PTRule -> ReaderT [PT] (Writer HelperFuns) PTRule
extractWithFlag flag (PTFun l id ts t _) r@(PTRule l' pq e) = do
    pts <- ask
    let helperFunName = gensym "extract" (namePattern (removeLeftCon pq flag)) pts
    let helperRule = PTRule l (PQApp l' helperFunName (varsAndLeftCon pq)) e
    let rt = case pq of (PQDes _ des _ _) -> destructorReturnType des pts
                        (PQApp _ _ _)     -> t
    let helperFuns = makeHelperFuns $ PTFun l helperFunName (varsAndLeftConTypes pts pq) rt [helperRule]
    lift $ tell helperFuns
    return $ PTRule l (removeLeftCon pq flag) (PApp dummyLocation helperFunName $ map toExpr $ varsReplaceLeftCon pq)    
  where
    varsAndLeftCon pq = recombine $ isolateLeftCon pq flag
      where
        recombine (c, (vs1, vs2)) = c:(vs1 ++ vs2)

    varsAndLeftConTypes pts pq = map snd $ (head rZipped1):((reverse $ tail rZipped1) ++ zipped2)
        where
            varTypes = collectVarTypes pts ts $ removeLeftCon pq flag
            (c, (vs1, vs2)) = isolateLeftCon pq flag
            zipped1 = zip (vs1++[c]) varTypes
            rZipped1 = reverse zipped1
            zipped2 = zip (reverse vs2) (reverse varTypes)

    varsReplaceLeftCon pq = recombine $ isolateLeftCon pq flag
      where
        recombine (con, (vs1, vs2)) = flip evalState 0 $ do
            newVs1 <- mapM convertToVar vs1
            v <- convertToVar con
            newVs2 <- mapM convertToVar vs2
            return $ v:(newVs1 ++ newVs2)

renameVars :: PP -> State Int PP
renameVars v@(PPVar _ _) = convertToVar v
renameVars (PPCon l id pps) = liftM (PPCon l id) $ mapM renameVars pps

renameVarsPQ :: PQ -> State Int PQ
renameVarsPQ (PQApp l id pps) = liftM (PQApp l id) $ mapM renameVars pps
renameVarsPQ (PQDes l id pps pq) = do
    newPQ <- renameVarsPQ pq
    newPPs <- mapM renameVars pps
    return $ PQDes l id newPPs newPQ

removeLeftConPPs :: [PP] -> ExtractFlag -> State Int [PP]
removeLeftConPPs ((v@(PPVar _ _)):pps) flag = do
    newV <- convertToVar v
    newPPs <- removeLeftConPPs pps NormalExtract
    return $ newV:newPPs
removeLeftConPPs ((c@(PPCon l id pps)):pps') flag
    | any con pps = do
        newPPs <- removeLeftConPPs pps NormalExtract
        newPPs' <- mapM renameVars pps'
        return $ (PPCon l id newPPs):newPPs'
    | otherwise = do
        newVOrOldC <- if flag == NormalExtract
                      then convertToVar c
                      else return c
        newPPs' <- if flag == NormalExtract
                   then mapM renameVars pps'
                   else removeLeftConPPs pps' NormalExtract
        return $ newVOrOldC:newPPs'    
removeLeftConPPs [] _ = return []

removeLeftConWithState :: PQ -> ExtractFlag -> State Int PQ
removeLeftConWithState (PQApp l id pps) flag = liftM (PQApp l id) (removeLeftConPPs pps flag)
removeLeftConWithState (PQDes l id pps pq) NormalExtract
    | conInPQ pq NormalExtract = do
        newPQ <- removeLeftConWithState pq NormalExtract
        newPPs <- mapM renameVars pps
        return $ PQDes l id newPPs newPQ
    | otherwise  = do
        newPQ <- renameVarsPQ pq
        newPPs <- removeLeftConPPs pps NormalExtract
        return $ PQDes l id newPPs newPQ
removeLeftConWithState _ _ = error "can't go here"

removeLeftCon :: PQ -> ExtractFlag -> PQ
removeLeftCon pq flag = evalState (removeLeftConWithState pq flag) 0

isolateLeftConPPs :: [PP] -> ExtractFlag -> (PP, ([PP], [PP]))
isolateLeftConPPs ((v@(PPVar _ _)):pps) flag = second (first (v:)) (isolateLeftConPPs pps NormalExtract)
isolateLeftConPPs ((c@(PPCon l id pps)):pps') flag
    | any con pps = second (second (++(concatMap collectVars pps'))) (isolateLeftConPPs pps NormalExtract)
    | otherwise   = if flag == NormalExtract
                    then (c, ([], (concatMap collectVars pps')))
                    else second (first ((collectVars c)++)) (isolateLeftConPPs pps' NormalExtract)

isolateLeftCon :: PQ -> ExtractFlag -> (PP, ([PP], [PP]))
isolateLeftCon (PQApp _ _ pps) flag = isolateLeftConPPs pps flag
isolateLeftCon (PQDes _ _ pps pq) NormalExtract
    | conInPQ pq NormalExtract = second (second (++(concatMap collectVars pps))) (isolateLeftCon pq NormalExtract)
    | otherwise       = second (first ((collectVarsPQ pq)++)) (isolateLeftConPPs pps NormalExtract)    
isolateLeftCon _ _ = error "can't go here"

conInPQ :: PQ -> ExtractFlag -> Bool
conInPQ (PQDes _ _ pps pq) flag                              = (any con pps) || (conInPQ pq flag)
conInPQ (PQApp _ _ pps) NormalExtract                        = any con pps
conInPQ (PQApp _ _ ((PPVar _ _):pps)) IgnoreLeftExtract      = any con pps
conInPQ (PQApp _ _ ((PPCon _ _ pps'):pps)) IgnoreLeftExtract = (any con pps) || (any con pps')

extractPatternMatching :: PT -> PTRule -> ReaderT [PT] (Writer HelperFuns) PTRule
extractPatternMatching fun r@(PTRule _ (PQDes _ _ pps pq) _)
    | any con (pps ++ (ppsForPQ pq)) = do
        replacedRule <- extractWithFlag NormalExtract fun r
        extractPatternMatching fun replacedRule
    | otherwise = return r
  where
    ppsForPQ (PQDes _ _ pps pq) = pps ++ (ppsForPQ pq)
    ppsForPQ (PQApp _ _ pps)    = pps
extractPatternMatching fun r@(PTRule _ pq@(PQApp _ _ pps) _)
    | conInPQ pq IgnoreLeftExtract = do
        replacedRule <- extractWithFlag IgnoreLeftExtract fun r
        extractPatternMatching fun replacedRule
    | otherwise = return r

disentangle :: [PT] -> [PT]
disentangle = extractHelperFuns extractPatternMatching

splitRule :: [PT] -> Type -> PTRule -> [PTRule]
splitRule pts t r@(PTRule l pq@(PQApp l' id ((PPVar _ id'):pps)) e)
    | null $ consForType pts  = [r]
    | otherwise               = map makeRuleForCon $ head (consForType pts)
  where
    consForType ((PTPos _ _ cons@((PTCon _ t' _ _):_)):pts')
        | t == t' = [cons]
        | otherwise          = consForType pts'
    consForType (_:pts') = consForType pts'
    consForType []       = []

    makeRuleForCon c =
        (PTRule l (PQApp l' id (convertPPs c))
            (substituteVars
                (zip (map getId (collectVarsPQ pq))
                    ((head $ convertPPs c):(concatMap collectVars $ tail $ convertPPs c)))
                e))
      where
        getId (PPVar _ vid) = vid

    convertPPs (PTCon _ _ cId ts) = flip evalState 0 $ do
        varsForCon <- mapM typeToVar ts
        let ppCon = PPCon l cId varsForCon
        otherVars <- mapM convertToVar pps
        return $ [ppCon] ++ otherVars

    typeToVar _ = convertToVar ()

    substituteVars pps (PApp l id es) = PApp l id (map (substituteVars pps) es)
    substituteVars pps (PVar l id) = toExpr $ fromJust $ lookup id pps
splitRule _ _ r = [r]

split :: [PT] -> [PT]
split pts = map splitInPT pts
  where
    splitInPT (PTFun l id ts@(t':ts') t rs) = PTFun l id ts t $ concatMap (splitRule pts t') rs
    splitInPT pt = pt

refuncLegal :: [PT] -> Maybe [PT]
refuncLegal pts = CoDataDefsDisjR.refuncLegal $ split $ disentangle pts