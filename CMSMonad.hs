{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving, MultiParamTypeClasses, FlexibleInstances, TypeSynonymInstances, FlexibleContexts, TypeFamilies, ScopedTypeVariables #-}
module CMSMonad
    ( CMS(..)
    , CMSState(..)
    , Content(..)
    , setCurrentPage
    , query
    , update
    ) where

import Acid
import Control.Applicative
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Trans
import CMSURL (CMSURL(..))
import Data.Acid                     (AcidState, EventState, EventResult, QueryEvent, UpdateEvent, query', update')
import Page.Acid
import Data.ByteString.Lazy          as LB (ByteString)
import Data.ByteString.Lazy.UTF8     as LB (toString)
import Data.Data
import qualified Data.Text           as T
import qualified Data.Text.Lazy      as TL

import Data.Time.Clock               (UTCTime)
import Data.Time.Format              (formatTime)

import HSP hiding (Request, escape)
import HSP.ServerPartT
import qualified HSX.XMLGenerator as HSX
import Happstack.Server
import System.Locale                 (defaultTimeLocale)
import Web.Routes
import Web.Routes.XMLGenT ()
import Web.Routes.Happstack

data CMSState 
    = CMSState { acidState   :: Acid 
               , currentPage :: PageId
               }

newtype CMS a = CMS { unCMS :: RouteT CMSURL (ServerPartT (StateT CMSState IO)) a }
    deriving (Functor, Applicative, Alternative, Monad, MonadIO, MonadPlus, Happstack, ServerMonad, HasRqData, FilterMonad Response, WebMonad Response, MonadState CMSState)

instance MonadRoute CMS where
    type URL CMS = CMSURL
    askRouteFn = CMS $ askRouteFn



query :: forall event. (QueryEvent event, GetAcidState (EventState event)) => event -> CMS (EventResult event)
query event =
    do as <- (getAcidState . acidState) <$> get
       query' (as :: AcidState (EventState event)) event

update :: forall event. (UpdateEvent event, GetAcidState (EventState event)) => event -> CMS (EventResult event)
update event =
    do as <- (getAcidState . acidState) <$> get
       update' (as :: AcidState (EventState event)) event

       

-- | update the 'currentPage' field of 'CMSState'
setCurrentPage :: PageId -> CMS ()
setCurrentPage pid =
    modify $ \s -> s { currentPage = pid }


-- * XMLGen / XMLGenerator instances for CMS

instance HSX.XMLGen CMS where
    type HSX.XML CMS = XML
    newtype HSX.Child CMS = CMSChild { unCMSChild :: XML }
    newtype HSX.Attribute CMS = FAttr { unFAttr :: Attribute }
    genElement n attrs children =
        do attribs <- map unFAttr <$> asAttr attrs
           childer <- flattenCDATA . map (unCMSChild) <$> asChild children
           HSX.XMLGenT $ return (Element
                              (toName n)
                              attribs
                              childer
                             )
    xmlToChild = CMSChild
    pcdataToChild = HSX.xmlToChild . pcdata

flattenCDATA :: [XML] -> [XML]
flattenCDATA cxml =
                case flP cxml [] of
                 [] -> []
                 [CDATA _ ""] -> []
                 xs -> xs                       
    where
        flP :: [XML] -> [XML] -> [XML]
        flP [] bs = reverse bs
        flP [x] bs = reverse (x:bs)
        flP (x:y:xs) bs = case (x,y) of
                           (CDATA e1 s1, CDATA e2 s2) | e1 == e2 -> flP (CDATA e1 (s1++s2) : xs) bs
                           _ -> flP (y:xs) (x:bs)

instance IsAttrValue CMS T.Text where
    toAttrValue = toAttrValue . T.unpack

instance IsAttrValue CMS TL.Text where
    toAttrValue = toAttrValue . TL.unpack
{-
instance EmbedAsChild CMS (Block t) where
  asChild b = asChild $
    <script type="text/javascript">
      <% show b %>
    </script>

instance IsAttrValue CMS (HJScript (Exp t)) where
  toAttrValue script = toAttrValue $ evaluateHJScript script

instance IsAttrValue CMS (Block t) where
  toAttrValue block = return . attrVal $ "javascript:" ++ show block

instance (IsName n) => HSX.EmbedAsAttr CMS (Attr n (HJScript (Exp a))) where
    asAttr (n := script) = return . (:[]) . FAttr $ MkAttr (toName n, attrVal $ show $ evaluateHJScript script)
-}
instance HSX.EmbedAsAttr CMS Attribute where
    asAttr = return . (:[]) . FAttr 

instance (IsName n) => HSX.EmbedAsAttr CMS (Attr n String) where
    asAttr (n := str)  = asAttr $ MkAttr (toName n, pAttrVal str)

instance (IsName n) => HSX.EmbedAsAttr CMS (Attr n Char) where
    asAttr (n := c)  = asAttr (n := [c])

instance (IsName n) => HSX.EmbedAsAttr CMS (Attr n Bool) where
    asAttr (n := True)  = asAttr $ MkAttr (toName n, pAttrVal "true")
    asAttr (n := False) = asAttr $ MkAttr (toName n, pAttrVal "false")

instance (IsName n) => HSX.EmbedAsAttr CMS (Attr n Int) where
    asAttr (n := i)  = asAttr $ MkAttr (toName n, pAttrVal (show i))

instance (IsName n) => HSX.EmbedAsAttr CMS (Attr n Integer) where
    asAttr (n := i)  = asAttr $ MkAttr (toName n, pAttrVal (show i))

instance (IsName n) => HSX.EmbedAsAttr CMS (Attr n CMSURL) where
    asAttr (n := u) = 
        do url <- showURL u
           asAttr $ MkAttr (toName n, pAttrVal (T.unpack url))
{-
instance HSX.EmbedAsAttr CMS (Attr String AuthURL) where
    asAttr (n := u) = 
        do url <- showURL (W_Auth u)
           asAttr $ MkAttr (toName n, pAttrVal url)
-}

instance (IsName n) => (EmbedAsAttr CMS (Attr n TL.Text)) where
    asAttr (n := a) = asAttr $ MkAttr (toName n, pAttrVal $ TL.unpack a)

instance (IsName n) => (EmbedAsAttr CMS (Attr n T.Text)) where
    asAttr (n := a) = asAttr $ MkAttr (toName n, pAttrVal $ T.unpack a)

instance EmbedAsChild CMS Char where
    asChild = XMLGenT . return . (:[]) . CMSChild . pcdata . (:[])

instance EmbedAsChild CMS String where
    asChild = XMLGenT . return . (:[]) . CMSChild . pcdata

instance EmbedAsChild CMS Int where
    asChild = XMLGenT . return . (:[]) . CMSChild . pcdata . show

instance EmbedAsChild CMS Integer where
    asChild = XMLGenT . return . (:[]) . CMSChild . pcdata . show

instance EmbedAsChild CMS Double where
    asChild = XMLGenT . return . (:[]) . CMSChild . pcdata . show

instance EmbedAsChild CMS Float where
    asChild = XMLGenT . return . (:[]) . CMSChild . pcdata . show

instance EmbedAsChild CMS TL.Text where
    asChild = asChild . TL.unpack

instance EmbedAsChild CMS T.Text where
    asChild = asChild . T.unpack

instance (EmbedAsChild CMS a) => EmbedAsChild CMS (CMS a) where
    asChild c = 
        do a <- XMLGenT c
           asChild a

instance (EmbedAsChild CMS a) => EmbedAsChild CMS (IO a) where
    asChild c = 
        do a <- XMLGenT (liftIO c)
           asChild a

{-
instance EmbedAsChild CMS TextHtml where
    asChild = XMLGenT . return . (:[]) . CMSChild . cdata . T.unpack . unTextHtml

instance EmbedAsChild CMS FbXML where
    asChild = XMLGenT . return . (:[]) . CMSChild
-}
instance EmbedAsChild CMS XML where
    asChild = XMLGenT . return . (:[]) . CMSChild

instance EmbedAsChild CMS () where
    asChild () = return []

instance EmbedAsChild CMS UTCTime where
    asChild = asChild . formatTime defaultTimeLocale "%a, %F @ %r"

instance AppendChild CMS XML where
 appAll xml children = do
        chs <- children
        case xml of
         CDATA _ _       -> return xml
         Element n as cs -> return $ Element n as (cs ++ (map unCMSChild chs))

instance SetAttr CMS XML where
 setAll xml hats = do
        attrs <- hats
        case xml of
         CDATA _ _       -> return xml
         Element n as cs -> return $ Element n (foldr (:) as (map unFAttr attrs)) cs

instance XMLGenerator CMS

data Content 
    = TrustedHtml T.Text
    | PlainText   T.Text
      deriving (Eq, Ord, Read, Show, Data, Typeable)

instance EmbedAsChild CMS Content where
    asChild (TrustedHtml html) = asChild $ cdata (T.unpack html)
    asChild (PlainText txt)    = asChild $ pcdata (T.unpack txt)
