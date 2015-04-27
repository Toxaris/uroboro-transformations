module UroboroTransformations.CoDataFragments.Refunc where

import Uroboro.Tree
import Uroboro.Error

import UroboroTransformations.CoDataFragments

import Debug.Trace

refuncExp :: PExp -> [(Location, Identifier, [Type], Type)] -> PExp
refuncExp v@(PVar _ _) _ = v
refuncExp (PApp l id es) fsigs
    | any hasSameId fsigs =
        PDes l id (map (flip refuncExp fsigs) $ tail es) (flip refuncExp fsigs $ head es)
    | otherwise           = PApp l id (map (flip refuncExp fsigs) es)
  where
    hasSameId (_, id', _, _) = id' == id
refuncExp pq _ = pq -- this makes it usable for CoDataDefsDisj.Refunc

illegalRule :: PTRule -> Bool
illegalRule (PTRule _ (PQDes l _ _ _) _) = True
illegalRule (PTRule _ (PQApp l _ []) _) = True
illegalRule (PTRule _ (PQApp l _ (pp:pps)) _) = (any (not . var) pps) || ((not . con) pp)
  where
    con (PPCon _ _ _) = True
    con _             = False

    var (PPVar _ _) = True
    var _           = False

refuncFunSig :: (Location, Identifier, [Type], Type) -> PTDes
refuncFunSig (l, id, t':ts, t) = PTDes l t id ts t'
refuncFunSig _ = undefined

refuncDef :: [(Location, Identifier, [Type], Type)] -> PT -> Maybe PT
refuncDef fs (PTPos l t _)    = Just $ PTNeg l t (map refuncFunSig fs)
refuncDef _ (PTNeg _ _ _)   = Nothing
refuncDef _ (PTFun _ _ _ _ _) = undefined

refuncRule :: PTRule -> [(Location, Identifier, [Type], Type)] -> PTRule
refuncRule (PTRule l (PQApp l' id ((PPCon l'' con pps'):pps)) e) fsigs =
    PTRule l (PQDes l' id pps (PQApp l'' con pps')) (refuncExp e fsigs)

refuncRules :: Identifier -> [PTRule] -> [(Location, Identifier, [Type], Type)] -> [PTRule]
refuncRules id rs fsigs = map (flip refuncRule fsigs) (filter hasSameId rs)
  where
    hasSameId (PTRule _ (PQApp _ _ ((PPCon _ id' _):_)) _) = id == id'
    hasSameId _ = undefined

funForCon :: [PTRule] -> [(Location, Identifier, [Type], Type)] -> PTCon -> PT
funForCon rs fsigs (PTCon l t id ts) = PTFun l id ts t (refuncRules id rs fsigs)

-- |Refunctionalize a program in the Data Fragment
-- Fails when not in the fragment
refunc :: [PT] -> Maybe [PT]
refunc pts = do
    let fsigs = funSigs pts
    ds <- mapM (refuncDef fsigs) (filter (not . isFun) pts)
    rs <- funRules pts illegalRule
    let fs = map (funForCon (concat rs) fsigs) (concatMap cons pts)
    return $ ds ++ fs
  where
    cons (PTPos _ _ cs) = cs
    cons _ = []