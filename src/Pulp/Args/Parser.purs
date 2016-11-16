module Pulp.Args.Parser where

import Prelude hiding (when)

import Control.Monad.Eff.Exception (error)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Error.Class
import Control.Monad.State.Class (get)
import Control.Alt
import Data.Array (many)
import Data.Either
import Data.Foldable (find, elem)
import Data.Traversable (traverse)
import Data.List (List)
import Data.List as List
import Data.String (joinWith)
import Data.Map as Map
import Data.Maybe (Maybe(..), maybe)
import Data.Tuple (Tuple(..))
import Data.Foreign (toForeign)

import Text.Parsing.Parser
import Text.Parsing.Parser.Combinators ((<?>), try, optionMaybe)
import Text.Parsing.Parser.Token as Token
import Text.Parsing.Parser.Pos as Pos

import Pulp.Args
import Pulp.System.FFI (AffN())

halt :: forall a. String -> OptParser a
halt err = lift $ throwError $ error err
-- halt err = ParserT $ \s ->
--   pure { consumed: true, input: s, result: Left (strMsg err) }

matchNamed :: forall a r. (Eq a) => { name :: a | r } -> a -> Boolean
matchNamed o key = o.name == key

matchOpt :: Option -> String -> Boolean
matchOpt o key = elem key o.match

-- | A version of Text.Parsing.Parser.Token.token which lies about the position,
-- | since we don't care about it here.
token :: forall m a. (Monad m) => ParserT (List a) m a
token = Token.token (const Pos.initialPos)

-- | A version of Text.Parsing.Parser.Token.match which lies about the position,
-- | since we don't care about it here.
match :: forall m a. (Monad m, Eq a) => a -> ParserT (List a) m a
match = Token.match (const Pos.initialPos)

-- | A version of Text.Parsing.Parser.Token.when which lies about the position,
-- | since we don't care about it here.
when :: forall m a. (Monad m) => (a -> Boolean) -> ParserT (List a) m a
when = Token.when (const Pos.initialPos)

lookup :: forall m a b. (Monad m, Eq b, Show b) => (a -> b -> Boolean) -> Array a -> ParserT (List b) m (Tuple b a)
lookup matches table = do
  next <- token
  case find (\i -> matches i next) table of
    Just entry -> pure $ Tuple next entry
    Nothing -> fail ("Unknown command: " <> show next)

lookupOpt :: Array Option -> OptParser (Tuple String Option)
lookupOpt = lookup matchOpt

lookupCmd :: Array Command -> OptParser (Tuple String Command)
lookupCmd = lookup matchNamed

opt :: Array Option -> OptParser Options
opt opts = do
  o <- lookupOpt opts
  case o of
    (Tuple key option) -> do
      val <- option.parser.parser key
      pure $ Map.singleton option.name val

arg :: Argument -> OptParser Options
arg a | a.required = do
  next <- token <|> fail ("Required argument \"" <> a.name <> "\" missing.")
  val <- a.parser next
  pure (Map.singleton a.name (Just val))
arg a = do
  val <- (try (Just <$> (token >>= a.parser))) <|> pure Nothing
  pure (maybe Map.empty (Map.singleton a.name <<< Just) val)

cmd :: Array Command -> OptParser Command
cmd cmds = do
  o <- lookupCmd cmds <?> "command"
  case o of
    (Tuple key option) -> pure option

extractDefault :: Option -> Options
extractDefault o =
  case o.defaultValue of
    Just def ->
      Map.singleton o.name (Just (toForeign def))
    Nothing ->
      Map.empty

-- See also https://github.com/purescript-contrib/purescript-parsing/issues/25
eof :: forall m a. (Monad m) => (List a -> String) -> ParserT (List a) m Unit
eof msg =
  get >>= \(ParseState (input :: List a) _ _) ->
    unless (List.null input) (fail (msg input))

parseArgv :: Array Option -> Array Command -> OptParser (Either Help Args)
parseArgv globals commands = do
  globalOpts <- globalDefaults <$> many (try (opt globals))
  command <- cmd commands
  helpForCommand command <|> normalCommand globalOpts command

  where
  normalCommand globalOpts command = do
    commandArgs <- traverse arg command.arguments
    commandOpts <- many $ try $ opt command.options
    restSep <- optionMaybe $ match "--"
    remainder <- maybe (pure []) (const (many token)) restSep
    eof unrecognised
    pure $ Right {
      globalOpts,
      command,
      commandOpts: Map.unions (commandOpts <> defs command.options),
      commandArgs: Map.unions commandArgs,
      remainder
      }

  helpForCommand command =
    matchHelp *> pure (Left (Help command))

  defs = map extractDefault
  unrecognised =
    ("Unrecognised arguments: " <> _)
    <<< joinWith ", "
    <<< List.toUnfoldable

  globalDefaults opts =
    Map.unions (opts <> defs globals)

  -- match a single "-h" or "--help"
  matchHelp =
    void (when (_ `elem` ["-h", "--help"]))

parse :: Array Option -> Array Command -> Array String -> AffN (Either ParseError (Either Help Args))
parse globals commands s =
  runParserT (List.fromFoldable s) (parseArgv globals commands)
