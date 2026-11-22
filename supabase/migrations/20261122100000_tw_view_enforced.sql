-- The SharePoint Worker now checks app_can('tw.view'), so this tick really opens and closes
-- access to the theatre records instead of only hiding the page.
update app_permissions
   set server = true,
       detail = 'Patient timings kept in SharePoint. The connection to SharePoint checks this tick'
 where key = 'tw.view';
