{-# OPTIONS_GHC -F -pgmFtrhsx #-}
module Admin.Console where

import Admin.URL
import Admin.Template
import Clckwrks
import Data.Text (Text)
import Page.Acid (PagesSummary(..))

consolePage :: Clck AdminURL Response
consolePage =
    do pages <- query PagesSummary
       template "Administration" () $
         <div>
          <ul>
           <a href=EditMenu>Edit Menu</a>
          </ul>
          <form action=NewPage method="POST" enctype="multipart/form-data">
           <button type="submit">Create New Page</button>
          </form>
          <% editList pages %>
         </div>

editList ::  [(PageId, Text)] -> GenChildList (Clck AdminURL)
editList [] = <%><p>There are currently no pages.</p></%>
editList pgs =
    <%>
     <p>Edit Page</p>
     <ul class="plain-list">
      <% mapM editPageLI pgs %>
     </ul>
    </%>
    where
      editPageLI :: (PageId, Text) -> GenXML (Clck AdminURL)
      editPageLI (pid, ttl) =
          <li><a href=(EditPage pid)><% ttl %></a></li>
