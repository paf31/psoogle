
module Handler.Search
  ( getSearchR
  , SearchResult(..)
  ) where

import Import
import Data.Trie (elems, submap)
import Data.Version (showVersion)
import qualified Web.Bower.PackageMeta as Bower

import Language.PureScript.Docs.AsHtml (makeFragment, renderMarkdown)
import TemplateHelpers (getFragmentRender)

import qualified Text.Blaze as Blaze
import qualified Text.Blaze.Html5 as Html5
import qualified Text.Blaze.Renderer.Text as BlazeT
import qualified Text.Parsec.Combinator as Parsec

import qualified Language.PureScript as P

import qualified XMLArrows

getSearchR :: Handler TypedContent
getSearchR = do
  mquery <- lookupGetParam "q"
  case mquery of
    Nothing -> redirect HomeR
    Just query -> do
      results <- case tryParseType query of
        Just ty | not (isSimpleType ty) -> searchForType ty query
        _ -> searchForName (toLower query)
      selectRep $ do
        provideRep (htmlOutput query results)
        provideRep (jsonOutput results)
  where
    htmlOutput :: Text -> [SearchResult] -> Handler Html
    htmlOutput query results = do
      fr <- getFragmentRender
      content <- defaultLayout $(widgetFile "search")
      sendResponseStatus ok200 content

    jsonOutput = fmap toJSON . traverse searchResultToJSON

    tryParseType :: Text -> Maybe P.Type
    tryParseType = hush (P.lex "") >=> hush (P.runTokenParser "" (P.parsePolyType <* Parsec.eof))
      where
        hush f = either (const Nothing) Just . f

    isSimpleType :: P.Type -> Bool
    isSimpleType P.TypeVar{} = True
    isSimpleType P.TypeConstructor{} = True
    isSimpleType _ = False

searchResultToJSON :: SearchResult -> Handler Value
searchResultToJSON result@SearchResult{..} = do
  url <- getFragmentRender <*> pure (routeResult result)
  let html = renderMarkdown hrComments
  return $
    object [ "package" .= hrPkgName
           , "version" .= showVersion hrPkgVersion
           , "markup" .= BlazeT.renderMarkup html
           , "text" .= BlazeT.renderMarkup (Blaze.contents html)
           , "info" .= toJSON hrInfo
           , "url" .= url
           ]

routeResult :: SearchResult -> ((Route App), Maybe Text)
routeResult SearchResult{..} =
  case hrInfo of
    PackageResult ->
      ( PackageR ppkgName
      , Nothing
      )
    ModuleResult modName ->
      ( PackageVersionModuleDocsR ppkgName pversion modName
      , Nothing
      )
    DeclarationResult typeOrValue modName declTitle _ ->
      ( PackageVersionModuleDocsR ppkgName pversion modName
      , Just $ drop 1 $ makeFragment typeOrValue declTitle
      )
  where
  ppkgName = PathPackageName hrPkgName
  pversion = PathVersion hrPkgVersion

searchForName :: Text -> Handler [SearchResult]
searchForName query = do
  db <- atomically . readTVar =<< (appDatabase <$> getYesod)
  return (map fst (take 50 (concat (elems (submap (encodeUtf8 query) db)))))

searchForType :: P.Type -> Text -> Handler [SearchResult]
searchForType ty query = do
    db <- atomically . readTVar =<< (appDatabase <$> getYesod)
    return (map fst (take 50 (sortBy (comparing snd) (mapMaybe matches (concat (elems db))))))
  where

    matches :: (SearchResult, Maybe P.Type) -> Maybe (SearchResult, Int)
    matches (result, Just ty2) = do
      typeScore <- compareTypes ty ty2
      let searchScore = typeScore + typeTextScore result
      return (result, searchScore)
    matches _ = Nothing

    -- This is an approximation to type subsumption / unification.
    -- This function returns Just a score if there is a possible match,
    -- or Nothing otherwise. Lower scores are better.
    compareTypes :: P.Type -> P.Type -> Maybe Int
    compareTypes (P.TypeVar _) (P.TypeVar _) = Just 0
    compareTypes t (P.TypeVar _) = Just (1 + typeComplexity t)
    compareTypes (P.TypeLevelString s1) (P.TypeLevelString s2) | s1 == s2 = Just 0
    compareTypes (P.TypeWildcard _) t = Just (typeComplexity t)
    compareTypes (P.TypeConstructor q1) (P.TypeConstructor q2) | compareQual q1 q2 = Just 0
    -- There is a special case for functions, since if the user _asked_ for a function,
    -- they probably don't want to see something more general of type 'f a' or 'f a b'.
    compareTypes (P.TypeApp a b) (P.TypeApp c d)
      | not (isFunction a && not (isFunction c)) = (+) <$> compareTypes a c <*> compareTypes b d
    compareTypes (P.ForAll _ t1 _) t2 = compareTypes t1 t2
    compareTypes t1 (P.ForAll _ t2 _) = compareTypes t1 t2
    compareTypes (P.ConstrainedType _ t1) t2 = compareTypes t1 t2
    compareTypes t1 (P.ConstrainedType _ t2) = compareTypes t1 t2
    compareTypes P.REmpty P.REmpty = Just 0
    compareTypes t1@P.RCons{} t2 = compareRows t1 t2
    compareTypes t1 t2@P.RCons{} = compareRows t1 t2
    compareTypes (P.KindedType t1 _) t2 = compareTypes t1 t2
    compareTypes t1 (P.KindedType t2 _) = compareTypes t1 t2
    -- Really, we should desugar any type operators here.
    -- Since type operators are not supported in search right now, this is fine,
    -- since we only care about functions, which are already in the correct
    -- order as they come out of the parser.
    compareTypes (P.ParensInType t1) t2 = compareTypes t1 t2
    compareTypes t1 (P.ParensInType t2) = compareTypes t1 t2
    compareTypes _ _ = Nothing

    isFunction :: P.Type -> Bool
    isFunction (P.TypeConstructor (P.Qualified _ (P.ProperName "Function"))) = True
    isFunction _ = False

    compareRows :: P.Type -> P.Type -> Maybe Int
    compareRows r1 r2 = sum <$>
      sequence [ compareTypes t1 t2
               | (name, t1) <- fst (P.rowToList r1)
               , (name', t2) <- fst (P.rowToList r2)
               , name == name'
               ]

    typeComplexity :: P.Type -> Int
    typeComplexity (P.TypeApp a b) = 1 + typeComplexity a + typeComplexity b
    typeComplexity (P.ForAll _ t _) = 1 + typeComplexity t
    typeComplexity (P.ConstrainedType _ t) = typeComplexity t + 1
    typeComplexity P.REmpty = 0
    typeComplexity (P.RCons _ t r) = 1 + typeComplexity t + typeComplexity r
    typeComplexity (P.KindedType t _) = typeComplexity t
    typeComplexity (P.ParensInType t) = typeComplexity t
    typeComplexity _ = 0

    compareQual :: Eq a => P.Qualified a -> P.Qualified a -> Bool
    compareQual (P.Qualified (Just mn1) a1) (P.Qualified (Just mn2) a2) = mn1 == mn2 && a1 == a2
    compareQual (P.Qualified _ a1) (P.Qualified _ a2) = a1 == a2

    -- a cheap hack to promote exact type matches
    typeTextScore :: SearchResult -> Int
    typeTextScore r = case hrInfo r of
      DeclarationResult _ _ _ (Just typeText)
        | toLower typeText == toLower query -> 0
      _ -> 1

renderMarkdownNoLinks :: Text -> Html
renderMarkdownNoLinks =
  renderMarkdown
  -- Wrapping in a div is necessary because of how XML arrows work
  >>> Html5.div
  >>> XMLArrows.run XMLArrows.replaceLinks
