{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -F -pgmFtrhsx #-}
module Page.API 
    ( PageId(..)
    , getPage
    , getPageId
    , getPageTitle
    , getPageContent
    , getPagesSummary
    , getPageSummary
    , getPageMenu
    , extractExcerpt
    ) where

import Acid
import Control.Applicative
import Control.Monad.State
import Control.Monad.Trans (MonadIO)
import CMSMonad
import Data.Text (Text)
import qualified Data.Text as Text
import Happstack.Server
import HSP hiding (escape)
import Page.Acid
import URL
import Text.HTML.TagSoup

getPage :: CMS url Page
getPage = 
    do CMSState{..} <- get
       mPage <- query (PageById currentPage)
       case mPage of
         Nothing -> escape $ internalServerError $ toResponse ("getPage: invalid PageId " ++ show (unPageId currentPage))
         (Just p) -> return p

getPageId :: CMS url PageId
getPageId = currentPage <$> get

getPageTitle :: CMS url Text
getPageTitle = pageTitle <$> getPage

getPageContent :: CMS url Content
getPageContent = 
    do mrkup <- pageSrc <$> getPage
       markupToContent mrkup

getPagesSummary :: CMS url [(PageId, Text)]
getPagesSummary = query PagesSummary

getPageMenu :: GenXML (CMS SiteURL)
getPageMenu = 
    do ps <- query PagesSummary
       case ps of
         [] -> <div>No pages found.</div>
         _ -> <ul class="page-menu">
                <% mapM (\(pid, ttl) -> <li><a href=(ViewPage pid) title=ttl><% ttl %></a></li>) ps %>
              </ul>

getPageSummary :: PageId -> CMS url Content
getPageSummary pid =
    do mPage <- query (PageById pid)
       case mPage of
         Nothing ->
             return $ PlainText $ Text.pack $ "Invalid PageId " ++ (show $ unPageId pid)
         (Just pge) -> 
             extractExcerpt pge

extractExcerpt :: (MonadIO m) => Page -> m Content
extractExcerpt Page{..} =
             case pageExcerpt of
               (Just excerpt) ->
                   markupToContent excerpt
               Nothing ->
                   do c <- markupToContent pageSrc
                      case c of
                        (TrustedHtml html) ->
                            let tags = parseTags html
                                paragraphs = sections (~== "<p>") tags
                                paragraph = case paragraphs of
                                              [] -> Text.pack "no summary available."
                                              (p:ps) -> renderTags $ takeThrough (not . isTagCloseName (Text.pack "p")) p
                            in return (TrustedHtml paragraph)
                      
takeThrough :: (a -> Bool) -> [a] -> [a]
takeThrough _ [] = []
takeThrough f (p:ps)
    | f p = p : takeThrough f ps
    | otherwise = []

        
    
