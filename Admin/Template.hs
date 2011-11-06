{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -F -pgmFtrhsx #-}
module Admin.Template where

import CMS

template :: 
    ( EmbedAsChild CMS headers
    , EmbedAsChild CMS body
    ) => String -> headers -> body -> CMS Response
template title headers body =
   toResponse <$> (unXMLGenT $
    <html>
     <head>
      <link type="text/css" href="/static/style.css" rel="stylesheet" />
      <title><% title %></title>
      <% headers %>
     </head>
     <body>
      <% body %>
     </body>
    </html>)
