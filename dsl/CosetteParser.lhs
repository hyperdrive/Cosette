= Parser for Cosette

Syntax and Parser for Cosette.

> module CosetteParser where
>
> import Text.Parsec.String (Parser)
> import Text.Parsec.String.Parsec (try)
> import Text.Parsec.String.Char
> import Text.Parsec.String.Combinator
> import Text.Parsec (parse,ParseError)
> import Control.Applicative ((<$>),(<*), (*>),(<*>), (<$), (<|>), many)
> import qualified Text.Parsec.String.Expr as E
> import Control.Monad
> import Data.Maybe
> import Data.Char
> import Test.HUnit
> import FunctionsAndTypesForParsing
> import Utilities
> import Debug.Trace

== SQL keywords

> sqlKeywords :: [String]                      
> sqlKeywords = [--join keywords
>                "natural"
>                ,"inner"
>                ,"outer"
>                ,"cross"
>                ,"left"
>                ,"right"
>                ,"full"
>                ,"join"
>                ,"on"
>                ,"using"
>                  -- subsequent clause keywords
>                ,"select"
>                ,"where"
>                ,"group"
>                ,"having"
>                ,"order"
>                , "as"
>                , "distinct"
>                ]

== Abstract Syntax

=== value expression

> data ValueExpr = NumLit Integer
>                | DIden String String              -- a.b
>                | BinOp ValueExpr String ValueExpr -- a.b + b.c etc
>                | Constant String                  -- constant variable
>                | VQE QueryExpr                    -- query expressions
>                | Agg String AggExpr             -- aggregation function
>                  deriving (Eq, Show)

> data AggExpr = AV ValueExpr
>              | AStar
>                deriving (Eq, Show)

=== predicate

> data Predicate = TRUE
>                | FALSE
>                | PredVar String [String]   -- generic predicate
>                | And Predicate Predicate
>                | Or Predicate Predicate
>                | Not Predicate
>                | Exists QueryExpr 
>                | Veq ValueExpr ValueExpr   -- equal
>                | Vgt ValueExpr ValueExpr   -- greater than
>                | Vlt ValueExpr ValueExpr   -- less than
>                  deriving (Eq, Show)

=== select item

> data SelectItem = Star         -- *
>                 | DStar String -- t.*
>                 | Proj ValueExpr String
>                   deriving (Eq, Show)


=== table ref (in from clause)

TODO: add Left Join, Semi join etc to table expression

> data TableExpr = TRBase String                -- base table
>                | TRUnion TableExpr TableExpr  -- union
>                | TRQuery QueryExpr            -- query
>                deriving (Eq, Show)

consider add the following to the definition of TableRef
| TRXProd TableRef TableRef
if convert list of relation to nested join is move to Cosette AST level

> data TableRef = TR TableExpr String           -- table expr, alias
>                 deriving (Eq, Show)

> getTe :: TableRef -> TableExpr
> getTe (TR t _) = t
> 

> getAlias :: TableRef -> String
> getAlias (TR _ s) = s

=== query expression

TODO: currently, grouping only supports columns rather than arbitrary value expressions

> data QueryExpr = Select
>                {qSelectList :: [SelectItem]
>                ,qFrom :: Maybe [TableRef]
>                ,qWhere :: Maybe Predicate
>                ,qGroup :: Maybe [ValueExpr]
>                ,qDistinct:: Bool}
>                | UnionAll QueryExpr QueryExpr
>                deriving (Eq, Show)

=== Cosette Statement

> data CosetteStmt = Schema String [(String, String)]
>                  | Table String String
>                  | Pred String [String]
>                  | Const String String
>                  | Query String QueryExpr
>                  | Verify String String
>                    deriving (Eq, Show)

== parsing ValueExp

> integer :: Parser Integer
> integer = do
>   n <- lexeme $ many1 digit
>   return $ read n

> num :: Parser ValueExpr
> num = NumLit <$> integer

> dIden :: Parser ValueExpr
> dIden = DIden <$> identifier <*> (dot *> identifier)

> constant :: Parser ValueExpr
> constant = Constant <$> identifier

term

> term :: [String] -> Parser ValueExpr
> term blackList = try dIden
>              <|> num
>              <|> constant
>              <|> parens (valueExpr [])

operators on values

> vtable :: [[E.Operator ValueExpr]]
> vtable = [[binary "*" E.AssocLeft
>           ,binary "/" E.AssocLeft]
>          ,[binary "+" E.AssocLeft
>           ,binary "-" E.AssocLeft]]
>   where
>     binary name assoc =
>         E.Infix (mkBinOp name <$ symbol name) assoc
>     mkBinOp nm a b = BinOp a nm b

valueExpr

currently, only supporting "agg(*)" or "agg(a.b)"

> aggExpr :: Parser AggExpr
> aggExpr = AV <$> dIden
>       <|> AStar <$ symbol "*"

> valueExpr' :: [String] -> Parser ValueExpr
> valueExpr' blackList = E.buildExpressionParser vtable (term blackList)

> valueExpr :: [String] -> Parser ValueExpr
> valueExpr blacklist = try (Agg <$> identifier <*> parens aggExpr)
>                   <|> try (VQE <$> queryExpr)
>                   <|> valueExpr' blacklist


== parsing select item

> star :: Parser SelectItem
> star = Star <$ symbol "*"

> dstar :: Parser SelectItem
> dstar = DStar <$> (identifier <* dot <* symbol "*")

> selectList :: Parser [SelectItem]
> selectList = keyword_ "select" *> commaSep1 selectItem

> distSelectList :: Parser [SelectItem]
> distSelectList = keyword_ "select" *> keyword_ "distinct" *> commaSep1 selectItem

> proj :: Parser SelectItem
> proj = try (Proj <$> valueExpr sqlKeywords <*> alias)
>        <|> (Proj <$> valueExpr sqlKeywords <*> return "")
>   where alias = keyword_ "as" *> identifierBlacklist sqlKeywords

> selectItem :: Parser SelectItem
> selectItem = star <|> try dstar <|> proj

== parsing predicate 

negation

> neg :: Parser Predicate
> neg = Not <$> (keyword "not" *> pterm)

predicate meta variable

> predVar :: Parser Predicate
> predVar = PredVar <$> identifier <*> (parens $ commaSep1 identifier)

binary operations on values

> binOpValue :: (ValueExpr -> ValueExpr -> Predicate) -> Parser Char -> Parser Predicate
> binOpValue con opParser = con <$> (valueExpr []) <*> (opParser *> (valueExpr []))

equal predicate

> eqp :: Parser Predicate
> eqp = binOpValue Veq eq

greater than

> gtp :: Parser Predicate
> gtp = binOpValue Vgt gt

less than

> ltp :: Parser Predicate
> ltp = binOpValue Vlt lt

exists clause

> exists :: Parser Predicate
> exists = Exists <$> (keyword_ "exists" *> parens queryExpr)

> pterm' :: Parser Predicate
> pterm' = try (parens predicate)
>      <|> try eqp
>      <|> try ltp
>      <|> try gtp
>      <|> exists
>      <|> try predVar
>      <|> neg
>      <|> (void $ keyword "true") *> return TRUE
>      <|> (void $ keyword "false") *> return FALSE

> pterm :: Parser Predicate
> pterm = lexeme pterm'

=== conjuctive predicate, 

> conp :: Parser Predicate
> conp = chainl1 pterm op
>   where
>     op = do
>       void $ lexeme $ keyword "and" 
>       return And

=== predicate

> predicate :: Parser Predicate 
> predicate = chainl1 conp op
>   where
>     op = do
>       void $ lexeme $ keyword "or"
>       return Or

== Query expression parsing

> whereClause :: Parser Predicate
> whereClause = keyword_ "where" *> predicate

=== from clause

TODO: for now, only base relations can be unioned in from clause.

> tableExpr :: Parser TableExpr
> tableExpr = try unionTe
>         <|> (TRQuery <$> queryExpr)

> baseTe :: Parser TableExpr
> baseTe = TRBase <$> identifier
>      <|> (parens unionTe)

> unionTe :: Parser TableExpr
> unionTe = try (TRUnion <$> baseTe <*> (unionall *> unionTe))
>       <|> baseTe

> fromItem :: Parser TableRef
> fromItem = try (TR <$> tableExpr <*> aliasIdentifier)
>        <|> TR <$> tableExpr <*> (keyword_ "as" *> aliasIdentifier)
>             where aliasIdentifier = identifierBlacklist sqlKeywords

> fromClause :: Parser [TableRef]
> fromClause = keyword_ "from" *> commaSep1 fromItem

=== grouping clause

> groupby :: Parser ()
> groupby = keyword_ "group" *> keyword_ "by"

> groupList :: Parser [ValueExpr]
> groupList = groupby *> commaSep1 dIden

=== queryExpr

Query without distinct

> bagQuery :: Parser QueryExpr
> bagQuery = Select
>            <$> selectList
>            <*> optionMaybe fromClause
>            <*> optionMaybe whereClause
>            <*> optionMaybe groupList
>            <*> (do return False)

Query with distinct

> setQuery :: Parser QueryExpr
> setQuery = Select
>            <$> distSelectList
>            <*> optionMaybe fromClause
>            <*> optionMaybe whereClause
>            <*> optionMaybe groupList
>            <*> (do return True)

Query expression

> spjQueryExpr :: Parser QueryExpr
> spjQueryExpr = try setQuery <|> bagQuery <|> (parens queryExpr)

> unionQueryExpr :: Parser QueryExpr
> unionQueryExpr = UnionAll <$>
>                  (spjQueryExpr <* unionall) <*>
>                  queryExpr

> queryExpr :: Parser QueryExpr
> queryExpr = try unionQueryExpr
>         <|> spjQueryExpr
>         <|> (parens queryExpr)
             
=== Parse Cosette statement 

Parse schema declaration

Note: we always treat "??"  as unknowns: type

> schemaItem :: Parser (String, String)
> schemaItem =  unknowns <|> normalAttr
>   where normalAttr = (,) <$> identifier
>                          <*> (symbol_ ":" *> identifier)
>         unknowns = (\_ -> ("unknowns", "type")) <$> unknown

> schemaStmt :: Parser CosetteStmt
> schemaStmt = Schema <$> (keyword_ "schema" *> identifier) <*> schema
>   where schema = parens $ commaSep1 schemaItem

Parse table declaration

> tableStmt :: Parser CosetteStmt
> tableStmt = Table <$> (keyword_ "table" *> identifier)
>                   <*> (parens $ identifier)

Parse predicate declaration

> predStmt :: Parser CosetteStmt
> predStmt = Pred <$> (keyword_ "predicate" *> identifier)
>                 <*> (parens $ commaSep1 identifier)

Parse constant declaration

> constStmt :: Parser CosetteStmt
> constStmt = Const <$> (keyword_ "constant" *> identifier)
>                   <*> (symbol_ ":" *> identifier)

Parse query declarations

> queryStmt :: Parser CosetteStmt
> queryStmt = Query <$> (keyword_ "query" *> identifier)
>                   <*> qp queryExpr
>   where qp = between st st
>         st = lexeme $ char '`'

Parse verify statement

> verifyStmt :: Parser CosetteStmt
> verifyStmt = Verify <$> (keyword_ "verify" *> identifier) <*> identifier

Parse cosette statement

> cosetteStmt :: Parser CosetteStmt
> cosetteStmt = schemaStmt
>           <|> tableStmt
>           <|> predStmt
>           <|> constStmt
>           <|> queryStmt
>           <|> verifyStmt

Parse cosette program

> cosetteProgram :: Parser [CosetteStmt]
> cosetteProgram = (`sepEndBy1` semiColon) $ cosetteStmt

extra pass on QueryExpr to infer alias if there no alias

> addAlias :: QueryExpr -> Either String QueryExpr
> addAlias (Select sl fr w g d) = do
>  sl' <- checkListErr $ map f sl
>  return (Select sl' fr w g d)
>   where f (Proj v s) = if s == ""
>                        then Proj <$> Right v <*> toName v
>                        else Right (Proj v s)
>         f other = Right other
> addAlias (UnionAll q1 q2) = UnionAll <$> addAlias q1 <*> addAlias q2 

> class Namely a where
>   toName :: a -> Either String String

you must explicitly name a query expr

> instance Namely ValueExpr where
>   toName (NumLit n) = Right $ "num" ++ (show n)
>   toName (DIden r a) = Right a
>   toName (BinOp v1 op v2) = do
>      s1 <- toName v1
>      so <- opToName op
>      s2 <- toName v2
>      return (s1 ++ "_" ++ so ++ "_" ++ s2)
>   toName (Constant s) = Right s
>   toName (Agg s ae) = do
>      an <- toName ae
>      return (s ++ "_" ++ an)
>   toName (VQE _) = Left "a query must be explicitly named."

> opToName :: String -> Either String String
> opToName "+" = Right "add"
> opToName "-" = Right "minus"
> opToName "*" = Right "times"
> opToName "/" = Right "div"
> opToName other = Left $ "unsupported op: " ++ other

> instance Namely AggExpr where
>   toName (AV v) = toName v
>   toName AStar = Right "star"

The function should be used to parse cosette program

> parseCosette :: String -> Either String [CosetteStmt]
> parseCosette source = 
>   let cs = parse (whitespace *> cosetteProgram <* eof) "" source in
>   case cs of
>     Left emsg -> Left (show emsg)
>     Right asts -> checkListErr $ map processCos asts 
>   where processCos (Query n q) = Query <$> Right n <*> (addAlias q)
>         processCos  o = Right o

== tokens

> whitespace :: Parser ()
> whitespace =
>     choice [simpleWhitespace *> whitespace
>            ,lineComment *> whitespace
>            ,blockComment *> whitespace
>            ,return ()]
>   where
>     lineComment = try (string "--")
>                   *> manyTill anyChar (void (char '\n') <|> eof)
>     blockComment = try (string "/*")
>                    *> manyTill anyChar (try $ string "*/")
>     simpleWhitespace = void $ many1 (oneOf " \t\n")

> lexeme :: Parser a -> Parser a
> lexeme p = p <* whitespace

> identifier :: Parser String
> identifier = lexeme ((:) <$> firstChar <*> many nonFirstChar)
>   where
>     firstChar = letter <|> char '_'
>     nonFirstChar = digit <|> firstChar

> symbol :: String -> Parser String
> symbol s = try $ lexeme $ do
>     u <- many1 (oneOf "<>=+-^%/*!|:")
>     guard (s == u)
>     return s

> openParen :: Parser Char
> openParen = lexeme $ char '('

> closeParen :: Parser Char
> closeParen = lexeme $ char ')'

> stringToken :: Parser String
> stringToken = lexeme (char '\'' *> manyTill anyChar (char '\''))

> dot :: Parser Char
> dot = lexeme $ char '.'

> eq :: Parser Char
> eq = lexeme $ char '='

> gt :: Parser Char
> gt = lexeme $ char '>'

> lt :: Parser Char
> lt = lexeme $ char '<'

> comma :: Parser Char
> comma = lexeme $ char ','

> semiColon :: Parser Char
> semiColon = lexeme $ char ';'

> unknown :: Parser ()
> unknown = char '?' *> (void $ char '?')

> unionall :: Parser ()
> unionall = keyword_ "union" *> (void $ keyword_ "all")

== helper functions

> keyword :: String -> Parser String
> keyword k = try $ do
>     i <- identifier
>     guard (i == k || map toLower i == k)
>     return k

> parens :: Parser a -> Parser a
> parens = between openParen closeParen

> commaSep :: Parser a -> Parser [a]
> commaSep = (`sepBy` comma)

> keyword_ :: String -> Parser ()
> keyword_ = void . keyword

> symbol_ :: String -> Parser ()
> symbol_ = void . symbol

> commaSep1 :: Parser a -> Parser [a]
> commaSep1 = (`sepBy1` comma)

> identifierBlacklist :: [String] -> Parser String
> identifierBlacklist bl = do
>     i <- identifier
>     guard (i `notElem` bl)
>     return i

> suffixWrapper :: (a -> Parser a) -> a -> Parser a
> suffixWrapper p a = p a <|> return a

== the parser api

> parseQueryExpr :: String -> Either String QueryExpr
> parseQueryExpr source = 
>   let r = parse (whitespace *> queryExpr <* eof) "" source in
>   case r of
>     Left e -> Left (show e)
>     Right ast -> addAlias ast

> parseValueExpr :: String -> Either ParseError ValueExpr
> parseValueExpr = parse (whitespace *> valueExpr [] <* eof) ""

== test cases

> makeSelect :: QueryExpr
> makeSelect = Select {qSelectList = []
>                     ,qFrom = Nothing
>                     ,qWhere = Nothing
>                     ,qGroup = Nothing
>                     ,qDistinct = False}

> makeTest :: (String, QueryExpr) -> Test
> makeTest (src, expected) = TestLabel src $ TestCase $ do
>     let gote = parseQueryExpr src
>     case gote of
>       Left e -> assertFailure $ e
>       Right got -> assertEqual src expected got
