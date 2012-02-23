{-# LANGUAGE CPP, RankNTypes, RecordWildCards, OverloadedStrings #-}
module Main where

import Control.Monad.State (evalStateT, get, modify)
import Clckwrks
import Clckwrks.Admin.Template (defaultAdminMenu)
import Clckwrks.Server
import Clckwrks.Media
import Clckwrks.Media.PreProcess (mediaCmd)
import qualified Data.ByteString.Char8 as C
import Data.List (intercalate)
import qualified Data.Map as Map
import Data.Monoid (mappend)
import Data.Text  (Text)
import Data.Text.Lazy.Builder (Builder)
import qualified Data.Text as Text
import System.Environment (getArgs)
import URL
import Web.Routes.Happstack
import qualified Theme.Blog as Blog

#ifdef PLUGINS
import Control.Monad.State (get)
import System.Plugins.Auto (PluginHandle, PluginConf(..), defaultPluginConf, initPlugins, withMonadIOFile)
#else
import PageMapper
#endif

clckwrksConfig :: ClckwrksConfig SiteURL
clckwrksConfig = ClckwrksConfig
      { clckHostname     = "localhost"
      , clckPort         = 8000
      , clckURL          = C
      , clckJQueryPath   = "/usr/share/javascript/jquery/"
      , clckJQueryUIPath = "/usr/share/javascript/jquery-ui/"
      , clckJSTreePath   = "../jstree/"
      , clckJSON2Path    = "../json2/"
      , clckThemeDir     = "../clckwrks-theme-basic/"
      , clckPluginDir    = [("media", "../clckwrks-plugin-media/")]
      , clckStaticDir    = "../clckwrks/static"
#ifdef PLUGINS
      , clckPageHandler  = undefined
#else
      , clckPageHandler  = staticPageHandler
#endif
      , clckBlogHandler  = staticBlogHandler
      }

-- * SitePlus

data SitePlus url a = SitePlus 
    { siteSite    :: Site url a
    , siteDomain  :: Text
    , sitePort    :: Int
    , siteAppRoot :: Text
    , sitePrefix  :: Text
    , siteShowURL :: url -> [(Text, Maybe Text)] -> Text
    , siteParsePathInfo :: C.ByteString -> Either String url
    }

instance Functor (SitePlus url) where
  fmap f sitePlus = sitePlus { siteSite = fmap f (siteSite sitePlus) }

mkSitePlus :: Text
           -> Int
           -> Text
           -> Site url a
           -> SitePlus url a
mkSitePlus domain port approot site =
    SitePlus { siteSite          = site 
             , siteDomain        = domain
             , sitePort          = port
             , siteAppRoot       = approot
             , sitePrefix        = prefix
             , siteShowURL       = showFn
             , siteParsePathInfo = parsePathSegments site . decodePathInfo
             }
    where
      showFn url qs =
        let (pieces, qs') = formatPathSegments site url
        in approot `mappend` (encodePathInfo pieces (qs ++ qs'))
      prefix = Text.concat $ [ Text.pack "http://" 
                             , domain
                             ] ++
                             (if port == 80
                                then []
                                else [Text.pack ":", Text.pack $ show port]
                             ) ++
                             [ approot ]

runSitePlus_ :: (Happstack m) => SitePlus url (m a) -> m (Either String a)
runSitePlus_ sitePlus =
    dirs (Text.unpack (siteAppRoot sitePlus)) $
         do rq <- askRq
            let r        = runSite (sitePrefix sitePlus) (siteSite sitePlus) (map Text.pack $ rqPaths rq)
            case r of
              (Left parseError) -> return (Left parseError)
              (Right sp)   -> Right <$> (localRq (const $ rq { rqPaths = [] }) sp)
        where
          escapeSlash :: String -> String
          escapeSlash [] = []
          escapeSlash ('/':cs) = "%2F" ++ escapeSlash cs
          escapeSlash (c:cs)   = c : escapeSlash cs

runSitePlus :: (Happstack m) => SitePlus url (m a) -> m a
runSitePlus sitePlus =
    do r <- runSitePlus_ sitePlus
       case r of
         (Left _)  -> mzero
         (Right a) -> return a

initPlugins :: ClckT SiteURL IO ()
initPlugins =
    do showFn <- askRouteFn
       let mediaCmd' :: forall url m. (Monad m) => (Text -> ClckT url m Builder)
           mediaCmd' = mediaCmd (\u p -> showFn (M u) p)
       addPreProcessor "media" mediaCmd'
       nestURL M $ addMediaAdminMenu
       dm <- nestURL C $ defaultAdminMenu
       mapM_ addAdminMenu dm

clckwrks :: ClckwrksConfig SiteURL -> IO ()
clckwrks cc' =
    do args <- getArgs
       let cc = case args of
                  [] -> cc'
                  (h:_) -> cc' { clckHostname = h }
       withClckwrks cc $ \clckState ->
           withMediaConfig Nothing "_uploads" $ \mediaConf ->
               let -- site     = mkSite (clckPageHandler cc) clckState mediaConf
                   site     = mkSite2 cc mediaConf
                   sitePlus = mkSitePlus (Text.pack $ clckHostname cc) (clckPort cc) Text.empty site
               in 
                 do clckState'    <- execClckT (siteShowURL sitePlus) clckState $ initPlugins
                    let sitePlus' = fmap (evalClckT (siteShowURL sitePlus) clckState') sitePlus
                    simpleHTTP (nullConf { port = clckPort cc }) (route cc sitePlus')

route :: Happstack m => ClckwrksConfig SiteURL -> SitePlus SiteURL (m Response) -> m Response
route cc sitePlus =
    do decodeBody (defaultBodyPolicy "/tmp/" (10 * 10^6)  (1 * 10^6)  (1 * 10^6))
       msum $ 
            [ jsHandlers cc
            , dir "favicon.ico" $ notFound (toResponse ())
            , dir "static"      $ serveDirectory DisableBrowsing [] (clckStaticDir cc)
            , dir "login"       $ seeOther ((siteShowURL sitePlus) (C $ Auth $ AuthURL A_Login) []) (toResponse ())
            , dir "admin"       $ seeOther ((siteShowURL sitePlus) (C $ Admin Console) []) (toResponse ())
            , runSitePlus sitePlus
            ]

{-

we can't register the pp callbacks instead the nestURL because then
the only callbacks will only be available when that route is active.

it is 'tricky' to register the callbacks outside, because the
callbacks might require information that is only available 'inside'
the monad. But, of course, that is silly now that we think about
it. Because that monad is only available when processing the route. But when doing the pp, that route may not be the one we are doing.

So, the reason it is hard to get the monad into the callback is because we shouldn't. The pp has to assume that the route being processed is not one of those.

Well, that is not actually a problem. The monad is really an environment in which a computation can run. And we can create that environment multiple ways.

The issue with the MediaT monad is that it includes the MediaURL. And so to work with that, we need to specify how to turn a MediaURL into a SiteURL. 

That is something we normally do in routeSite via 'nestURL M'. But that means we have to repeat ourselves.

we could have a function like withMediaT to contruct a temporary MediaT monad to be used when registering the callback. Though there is a danger there, because some of the information use to register the callback might become stale.

In theory, we would like to do some stuff in the ClckT monad before start listening to incoming requests. However, to run the ClckT monad we need to provide the show function. Normally that is done transparently via implSite / site / etc.

Though it seems the information we need comes from Site not implSite.
-}
routeSite :: ClckwrksConfig u -> MediaConfig -> SiteURL -> Clck SiteURL Response
routeSite cc mediaConfig url =
    do case url of
        (C clckURL)  -> nestURL C $ routeClck cc clckURL
        (M mediaURL) -> 
            do showFn <- askRouteFn
               -- FIXME: it is a bit silly that we wait this  long to set the mediaClckURL
               -- would be better to do it before we forkIO on simpleHTTP
               nestURL M $ runMediaT (mediaConfig { mediaClckURL = (showFn . C) })  $ routeMedia mediaURL
{-      
mkSite :: ClckwrksConfig u -> ClckState -> MediaConfig -> Site SiteURL (ServerPart Response)
mkSite cc clckState media = setDefault (C $ ViewPage $ PageId 1) $ mkSitePI route'
    where
      route' f u =
          evalStateT (unRouteT (unClckT $ routeSite cc media u) f) clckState
-}
-- FIXME: something seems weird here.. we do not use the 'f' in route'
mkSite2 :: ClckwrksConfig u -> MediaConfig -> Site SiteURL (ClckT SiteURL (ServerPartT IO) Response)
mkSite2 cc mediaConfig = setDefault (C $ ViewPage $ PageId 1) $ mkSitePI route'
    where
      route' :: (SiteURL -> [(Text.Text, Maybe Text.Text)] -> Text.Text) -> SiteURL -> ClckT SiteURL (ServerPartT IO) Response
      route' f url =
          routeSite cc mediaConfig url


#ifdef PLUGINS
main :: IO ()
main = 
  do ph <- initPlugins 
     putStrLn "Dynamic Server Started."
     clckwrks (clckwrksConfig { clckPageHandler = dynamicPageHandler ph })

dynamicPageHandler :: PluginHandle -> Clck ClckURL Response
dynamicPageHandler ph =
  do fp <- themePath <$> get
     withMonadIOFile "PageMapper.hs" "pageMapper" ph (\pc -> pc { pcGHCArgs = [ "-i" ++ fp]  }) notLoaded page
  where
    page :: [String] -> XMLGenT (Clck url) XML -> Clck url Response
    page _errs (XMLGenT part) = toResponse <$> part
    notLoaded errs =
      internalServerError $ toResponse $ unlines errs
#else
main :: IO ()
main = 
  do putStrLn "Static Server Started."
     clckwrks clckwrksConfig

staticPageHandler :: Clck ClckURL Response
staticPageHandler = toResponse <$> unXMLGenT pageMapper
#endif

staticBlogHandler :: Clck ClckURL Response
staticBlogHandler = toResponse <$> unXMLGenT Blog.page

