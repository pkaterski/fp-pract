{-#LANGUAGE BlockArguments #-}
{-#LANGUAGE LambdaCase #-}

import Parser
import Control.Applicative

type State = [Definition]

newtype Eval a = Eval {runEval :: State -> Either String (State, a)}

instance Functor Eval where
  fmap g ev = Eval \s -> case runEval ev s of
    Right (s', x) -> Right (s', g x)
    Left err      -> Left err

instance Applicative Eval where
  pure x = Eval \s -> Right (s, x)
  fx <*> sx = Eval \s -> do
    (s', f)  <- runEval fx s
    (s'', x) <- runEval sx s'
    pure (s'', f x)

instance Monad Eval where
  sx >>= f = Eval \s -> do
    (s', x)  <- runEval sx s
    (s'', y) <- runEval (f x) s'
    pure (s'', y)

get :: Eval State
get = Eval \s -> Right (s, s)

put :: State -> Eval ()
put s = Eval \_ -> Right (s, ())

oops :: String -> Eval a
oops err = Eval \s -> Left $ err -- ++ "\n the env is:\n" ++ show s

searchDefinition :: String -> [Definition] -> Maybe SchemeValue
searchDefinition _ [] = Nothing
searchDefinition s (Definition s' l@(Lambda args _ body):ds) =
  if s == s'
  then case args of
    [] -> Just body -- lambda w/ no args is a val
    _  -> Just $ SchemeLambda l
  else searchDefinition s ds

isDefined :: String -> [Definition] -> Bool
isDefined s ds = case searchDefinition s ds of
  Just _  -> True
  Nothing -> False


evalIf :: SchemeValue -> Eval SchemeValue
evalIf (SchemeIf p t f) = do
  p' <- eval p
  case p' of
    SchemeBool True  -> eval t
    SchemeBool False -> eval f
    _                -> oops $ "condition in if not a bool: " ++ show p

evalCond :: SchemeValue -> Eval SchemeValue
evalCond (SchemeCond ((p,v):xs)) = do
  p' <- eval p
  case p' of
    SchemeBool True  -> eval v
    SchemeBool False -> evalCond $ SchemeCond xs
    _                -> oops $ "condition in cond not a bool: " ++ show p


evalDefinition :: SchemeValue -> Eval SchemeValue
evalDefinition (SchemeDefinition v@(Definition s _)) = do
  currDefs <- get
  if isDefined s currDefs
  then oops $ "already existing def: " ++ show v
  else
    do put (v:currDefs)
       pure $ SchemeDefinition v

evalSynonym :: SchemeValue -> Eval SchemeValue
evalSynonym v@(SchemeSynonym s) = do
  currDefs <- get
  case searchDefinition s currDefs of
    Just d -> pure d
    Nothing -> oops $ "unknow variable used: " ++ show v


evalFunctionCall :: SchemeValue -> Eval SchemeValue
evalFunctionCall v@(SchemeFunctionCall s args) =
  if isBuildin v
  then evalBuildin v
  else do
  currDefs <- get
  case searchDefinition s currDefs of
    Just (SchemeLambda (Lambda params ldef body)) -> do
      ds <- match args params
      case runEval (evalRec $ body:[]) (ds++ldef++currDefs) of
       Right (_,res) -> pure $ last res
       Left s        -> oops $ "local eval err: " ++ s
    Just s -> do -- really strange. TODO: look at this
      l <- eval s
      evalLambdaCall (SchemeLambdaCall l args)
    Nothing -> oops $ "unknow function is called: " ++ show v


evalLambdaCall :: SchemeValue -> Eval SchemeValue
evalLambdaCall (SchemeLambdaCall l args) = do
  l' <- eval l
  case l' of
    (SchemeLambda (Lambda params ldef body)) -> do
      currDefs <- get
      ds <- match args params

      case runEval (evalRec $ body:[]) (ds++ldef++currDefs) of
       Right (_,res) -> pure $ last res
       Left s        -> oops $ "local eval err: " ++ s


    _ -> oops $ "trying to call a non-function: " ++ show l



match :: [SchemeValue] -> [String] -> Eval [Definition]
-- match args params
match (a:as) (p:ps) = do
  a' <- case a of
    SchemeDefinition (Definition _ l) ->
      pure $ Definition p l
    _ -> do
      a' <- eval a
      pure $ Definition p (Lambda [] [] a')
  xs <- match as ps
  pure $ a' : xs
match [] [] = pure []
match [] ps  = oops $ "match: args are not enough, unused params: " ++ show ps
match as []  = oops $ "match: params are not enough, unused args: " ++ show as


isBuildin :: SchemeValue -> Bool
isBuildin (SchemeFunctionCall s _) = s `elem` ["+", "*", "car", "cdr", "cons", "eq?"]


evalBuildin :: SchemeValue -> Eval SchemeValue
evalBuildin (SchemeFunctionCall "+" xs) = evalBuildinPlus xs
evalBuildin (SchemeFunctionCall "*" xs) = evalBuildinProd xs
evalBuildin (SchemeFunctionCall "car" xs) = evalBuildinCar xs
evalBuildin (SchemeFunctionCall "cdr" xs) = evalBuildinCdr xs
evalBuildin (SchemeFunctionCall "cons" xs) = evalBuildinCons xs
evalBuildin (SchemeFunctionCall "eq?" xs) = evalBuildinEq xs


evalBuildinPlus :: [SchemeValue] -> Eval SchemeValue
evalBuildinPlus (x:xs) = do
  x' <- eval x
  xs' <- evalBuildinPlus xs
  case x' of
    SchemeInteger i -> case xs' of
      SchemeInteger j -> pure $ SchemeInteger $ i + j
      SchemeDouble j -> pure $ SchemeDouble $ fromIntegral i + j
    SchemeDouble i -> case xs' of
      SchemeDouble j -> pure $ SchemeDouble $ i + j
      SchemeInteger j -> pure $ SchemeDouble $ i + fromIntegral j

    _ -> oops $ "cannot sum non-number: " ++ show x
evalBuildinPlus [] = pure $ SchemeInteger 0

evalBuildinProd :: [SchemeValue] -> Eval SchemeValue
evalBuildinProd (x:xs) = do
  x' <- eval x
  xs' <- evalBuildinProd xs
  case x' of
    SchemeInteger i -> case xs' of
      SchemeInteger j -> pure $ SchemeInteger $ i * j
      SchemeDouble j -> pure $ SchemeDouble $ fromIntegral i * j
    SchemeDouble i -> case xs' of
      SchemeDouble j -> pure $ SchemeDouble $ i * j
      SchemeInteger j -> pure $ SchemeDouble $ i * fromIntegral j

    _ -> oops $ "cannot sum non-number: " ++ show x
evalBuildinProd [] = pure $ SchemeInteger 1

evalBuildinCar :: [SchemeValue] -> Eval SchemeValue
evalBuildinCar (x:[]) = do
  x' <- eval x
  case x' of
    SchemeList l -> pure $ head l
    _ -> oops $ "non-list argument to car: " ++ show x
evalBuildinCar xs = oops $ "more than one argument to car: " ++ show xs


evalBuildinCdr :: [SchemeValue] -> Eval SchemeValue
evalBuildinCdr (x:[]) = do
  x' <- eval x
  case x' of
    SchemeList l -> pure $ SchemeList $ tail l
    _ -> oops $ "non-list argument to cdr: " ++ show x
evalBuildinCdr xs = oops $ "more than one argument to cdr: " ++ show xs


evalBuildinCons :: [SchemeValue] -> Eval SchemeValue
evalBuildinCons (x:ys:[]) = do
  x' <- eval x
  ys' <- eval ys
  case ys' of
    SchemeList ls -> pure $ SchemeList (x':ls)
    _ -> oops $ "cons to non-schemelist: " ++ show ys
evalBuildinCons xs = oops $ "cons wrong number of arguments: " ++ show xs

evalBuildinEq :: [SchemeValue] -> Eval SchemeValue
evalBuildinEq (x:y:[]) = do
  x' <- eval x
  y' <- eval y
  pure $ SchemeBool $ x' == y'
evalBuildinEq xs = oops $ "eq? wrong number of arguments: " ++ show xs

evalLambda :: SchemeValue -> Eval SchemeValue
evalLambda (SchemeLambda (Lambda ps ds b)) = do
  currDefs <- get
  pure $ SchemeLambda $ Lambda ps (ds++currDefs) b


eval :: SchemeValue -> Eval SchemeValue
eval v@(SchemeBool _) = pure v
eval v@(SchemeInteger _) = pure v
eval v@(SchemeDouble _) = pure v
eval v@(SchemeString _) = pure v
eval v@(SchemeSymbol _) = pure v
eval v@(SchemeList _) = pure v
eval v@(SchemeLambda _) = evalLambda v
eval v@(SchemeIf _ _ _) = evalIf v
eval v@(SchemeCond _) = evalCond v
eval v@(SchemeDefinition _) = evalDefinition v
eval v@(SchemeSynonym _) = evalSynonym v
eval v@(SchemeFunctionCall _ _) = evalFunctionCall v
eval v@(SchemeLambdaCall _ _) = evalLambdaCall v

evalRec :: [SchemeValue] -> Eval [SchemeValue]
evalRec xs = sequenceA $ map eval xs


defaultDefs =
  [ Definition "else" $ Lambda [] [] (SchemeBool True)
  ]


main :: IO ()
main = do
  x <- readFile "test/example2.scm"
  putStrLn $
    case many schemeP `runParser` x of
      Just (s,_) ->
        case runEval (evalRec s) defaultDefs of
          Right (_, res) -> disp res
          Left err       -> err
      Nothing -> "didn't parse"
  return ()


disp :: [SchemeValue] -> String
disp (SchemeDefinition _:xs) = disp xs
disp (x:xs) = show x ++ "\n" ++ disp xs
disp [] = ""

