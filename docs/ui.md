# The console's pages

The rules the pages of the console follow, for a contributor who adds a page or changes
one. The words on them are in [lingo.md](lingo.md); where the code lives is in
[architecture.md](architecture.md).

## The shell

Every page behind sign-in renders inside `ApiaryWeb.Layouts.app/1`, which takes the
page's active navigation item (`nav`), the counts the sidebar shows (`counts`), the width
of its column (`width`), on a page of a level's settings the level's sections and the
page's section (`sections`, `section`), on a list narrowed to one target that target
(`narrowed`) and, in `crumb` slots, the page's segments of the breadcrumb. The shell shows
one scope's sidebar at a time, the one the page belongs to, or, on a person's
page and an Instance page, the one the person came from (Two levels, below).

- **A page belongs to one scope**: a workspace, an organisation, the person or the
  Instance. The navigation is data, `ApiaryWeb.Nav.Entry` values, and the entry a page
  passes as `nav` names its scope (`place`) and so the sidebar it shows. A new item of the
  core goes in `nav_entries/1` of `ApiaryWeb.Layouts`, an edition's in its
  `ApiaryWeb.Edition.nav_entries/1`, and never in a page. A page that no entry names
  passes its scope as `place` instead: its sidebar is that scope's, with no entry current.
  An Instance page passes `:instance`, and keeps the sidebar the person came from.
- **The top bar** is one `<header aria-label="Top bar">`, 48 px, across the window and
  above the sidebar, first in the tab order after Skip to content. From the left: the
  **breadcrumb** (`<nav id="breadcrumb">`: the organisation first, its tile and its name,
  then the workspace, each a link to its home, and the page's segments, a target or a
  record, the last one the page with `aria-current="page"`. A page of a workspace or an
  organisation starts them with its section's name as the sidebar words it: a link to the
  section's page on a page under it (`Acme / Main / Runs / Run 14`, also where that
  run is not found, and `Acme / Main / Runs` where the address is no run's number), the page
  itself on the section's page (`Acme / Main / Runs`, `Acme / Main / Overview`,
  `Acme / Main / Policy`, `Acme / Overview`, `Acme / Audit log`). A thing with tabs (a
  target, a machine, a run) is the page itself on its first tab and a link
  to it on the others; on a page of a level's settings the frame writes the level (`#breadcrumb-settings`, "Workspace settings" or
  "Organisation settings", a link to its General) and the section (`#breadcrumb-section`,
  the page itself, or a link where segments follow it), so the page adds only what follows
  the section; on a person's page Your
  settings, its section and the page's segments, such as an edition's `Your settings /
  Organisations / New organisation`, and on an Instance page Instance settings and its
  section the same way, the section a link where segments follow it), then **Search or jump to**,
  **New** and the **account menu**. The bar has no mark: Qory Apiary is the sidebar's
  foot. A page's title stays its `<h1>`; the breadcrumb is navigation. A page without a
  person has no sidebar, and the Qory Apiary menu opens downward from the bar's left.
- **The organisation menu and the workspace menu.** The chevron beside the organisation
  opens the organisation menu, and the one beside the workspace the workspace menu, each a
  separate dropdown under its segment (a disclosure: the chevron's `aria-expanded` and
  `aria-controls`, the panel a named `role="group"`; the `Switcher` hook). A menu shows only
  when there is another place to go or an entry: the organisation menu with more than one
  place, or an edition's entry after the places (`ApiaryWeb.Edition.switcher_entries/1`);
  the workspace menu with another workspace of the organisation, or an edition's entry for
  it (`ApiaryWeb.Edition.workspace_switcher_entries/1`). So an instance with one
  organisation and one workspace shows neither, and the segments are links and nothing
  more.
  The organisation menu has a search, then two panels that each scroll separately: on the
  left the organisations the person reaches, by name, the ones they are a member of first
  and the edition's groups of places under their headings
  (`ApiaryWeb.Edition.place_group/1`), each folded behind its heading, a button with the
  group's count, unless the page's organisation is in it; on the right, under a heading that
  names it, the workspaces of the organisation pointed at, by name. On opening, the page's
  organisation is pointed at and scrolled to; then the one with focus, or the one under the
  mouse once it has rested there for 100 ms, so a pointer crossing others on its way to the
  right panel changes nothing. Each organisation's `›` shows its workspaces. An
  organisation's link lands in the workspace the person last used there; a workspace's lands
  in that workspace. At its foot are Your organisations and the edition's entries.
  The workspace menu has a search, then this organisation's workspaces by name, and no
  other organisation's; at its foot, the edition's entries for it.
  Every link goes through `/:org/:workspace/switch/:section` or `/:org/-/switch/:section`
  (`ApiaryWeb.SwitchController`), which asks the destination's scope when it is
  followed and lands on the reader's page there, its list page where the page names one
  thing by its id, else the section, else the overview; from an organisation's
  page, on the overview. The search filters as the reader types: the organisation menu by an
  organisation's name and slug, keeping one with a matching workspace with only those
  workspaces, and opening every group it finds one in; the workspace menu by a
  workspace's name and slug. ↓ from the search goes to the first row, ↑ and ↓ move within
  a panel, → and ← between an organisation and its workspaces, Enter in the search follows
  the first match, Escape closes and gives focus back. On a phone a menu is a sheet under
  the bar showing one panel at a time: `›` shows an organisation's workspaces in place of
  the organisations, under a button back to them, Organisations. A phone's bar names the
  page alone, so there the drawer's head holds, where either has a menu, the organisation
  and, on a workspace's page, the workspace (`#drawer-place`), each a button that opens
  its menu where it has one, else its name: the drawer closes, the menu opens as the sheet
  under the bar, and Escape closes it and gives focus to the bar's Open menu button.
- **Search or jump to** (⌘K, Ctrl+K, and / outside a field) is a `<dialog>` under the
  `Palette` hook, which asks `ApiaryWeb.JumpController` what matches, 150 ms after the
  reader stops typing, at the sidebar's level: `/:org/:workspace/jump` where the sidebar is
  a workspace's, as on a person's page or an Instance page shown with one, else
  `/:org/jump`. It finds the pages of the navigation, the sections of each
  Settings and of the Instance, and Preferences' theme and shortcuts, each
  named by whose it is where two scopes share a name (Workspace overview, Organisation
  settings › People, Instance settings › Configuration; an edition's entry by its `long_label`) and found by its other words too (members, audit, dark), targets,
  runs by id or title, places, what New offers and, for what is typed, the deletions the
  reader may take. Every word of it comes from the server; words Forager reported are written
  as text.
- **New** offers only what the reader may do where the page is
  (`ApiaryWeb.Layouts.new_entries/2`): on a workspace's page New machine, and New pool
  for one who may set a pool's limit too (`node.set_limit`), then, on every page, Invite
  people; before the core's, whatever the edition offers there
  (`ApiaryWeb.Edition.new_entries/2`); each entry asked of the workspace or the
  organisation as its place says. **The account menu** holds who they are, their email
  over "Your personal account" (`#user-menu-account`; an account has no name), then
  Settings (`#user-menu-settings`, the person's settings, `/users/settings`) and Your
  organisations, the theme (Auto, Light, Dark), then Log out; an edition's entries follow
  the core's of their group (`ApiaryWeb.Edition.account_menu_entries/1`), its group
  `:instance` after the theme. Nothing in it is about Qory Apiary itself, and so not the
  Instance level: Instance settings is the Qory Apiary menu's (below).
- **The sidebar** holds the scope's pages and nothing else, in groups, each a named
  `<nav>`: a workspace's Overview, then Record (Runs, Targets, Machines) and Guard
  (Network access, then Policy, which carries the policy's mode word alone, how many
  targets override the mode in its title; without `security` Network access alone, the record
  of it), then the targets the person pinned (`counts.pins`, the first seven in the
  order pinned, `Apiary.Targets.list_pins/2`; on a target's page its pin is the current
  entry); an organisation's
  Overview and Audit log, then the edition's groups (`ApiaryWeb.Edition.nav_sections/0`);
  the person's Account, Preferences and Organisations under Your settings, the sidebar of
  those pages only where there is no workspace to show (Two levels, below). It is
  never replaced: a page of a scope's settings keeps the scope's sidebar. A group whose
  feature is off, or hidden from the reader, is absent, not greyed.
- **The current entry.** `aria-current="page"` marks only the entry of the exact page; a
  parent of the page carries `aria-current="true"`: the sidebar's Workspace settings or
  Organisation settings while its sections are the second column, whose entry is the exact
  page, and a second column's section on a page under it, one that passes `crumb` segments
  (Invite people). A section's tabs are one page, the section's: the column
  marks it as the page on each.
- **The sidebar's foot** holds the scope's settings, named after the level: **Workspace
  settings** (`#nav-settings`) or **Organisation settings** (`#nav-organisation`), never a
  bare Settings, and so its tooltip while folded; the current entry on every page of them
  (General, or an entry of the section `:settings`, such as People), marked as their
  parent (The current entry, above),
  then, under a rule, **the Qory Apiary menu** (`#brand-menu`): the mark and the product's
  name on the instance (`Apiary.ProductName.button_name/0`: the name an instance admin set
  in Instance settings › General, else the edition's,
  `c:ApiaryWeb.Edition.product_name/0`, Qory Apiary in the core's), a name too long for
  the sidebar cut with an ellipsis and whole on hover, no version, opening upward to what
  is about the product rather than the
  person: first, only for whoever may open a section of the Instance level
  (`ApiaryWeb.Layouts.instance_sections/1`, read with the navigation's counts), **Instance
  settings** (`#brand-menu-instance`), leading to the first, under it a rule; then Docs,
  Changelog with the running version faint at its right (`#brand-version`), a rule and
  Source on GitHub; and at the right of it the fold. Folded, and from the bar on a page
  without a sidebar, it is the same menu. Beside a name an instance admin set that is not
  Qory Apiary (`Apiary.ProductName.powered_by?/0`), the foot says "Powered by Qory Apiary"
  in plain text: a faint line under the menu's row (`#powered-by`), in the sidebar and the
  drawer; folded, and from the bar, the menu's last line instead (`#brand-menu-powered`).
- **Two levels.** The sidebar is the level's, a workspace's or an organisation's, on every
  page of the level, its settings included. A page of a level's settings, of Your settings
  or of the Instance opens the level's sections as a **second column** beside the sidebar
  (`Layouts.app/1`'s `sections` and `section`): from 1024 px a column under its heading,
  which names the level (Workspace settings, Organisation settings, Your settings,
  Instance settings; `#<column>-heading`) and, beneath it, the place (the workspace's or the
  organisation's name, `#<column>-place`), and names the column's navigation. Below
  1024 px, at every width, the heading is one full-width button under the top bar,
  `[ Workspace settings · Main ▾ ]` (`#settings-disclosure`, `aria-expanded`,
  `aria-controls` the list), that opens the same links in place, one per line, pushing the
  page down: not a modal, not sticky. Escape on it or on a link closes it and gives it the
  focus; a navigation renders it closed. The drawer holds none of its sections. The level
  leaves the page: a settings page's `<h1>` is its section. Each keeps the ids its
  list had: `#settings-tabs` and `settings-tab-<key>` for a level's Settings,
  `#nav-group-account` and `nav-<key>` for a person's, `#instance-tabs` and
  `instance-tab-<key>` for the Instance's. A level with fewer than two sections gets no
  second column, and Runs, Network access and Targets never get one. A person's
  page and an Instance page keep the sidebar the person came from, the workspace the session
  remembers; with no workspace, the person's sidebar is their sections alone. A thing's
  page, a target, a machine or a run, keeps its tabs (`PageComponents.page_tabs/1`), and a
  machine's Settings tab lists its few sections in the page.
- **Narrowing.** On Runs and on Network access narrowed to one target, the sidebar's Runs
  and Network access carry the target (`Layouts.app/1`'s `narrowed`, built with
  `ApiaryWeb.Narrowing.carried/2`): its id in the address, named by its path, and its
  system only where two systems share the path, each entry's accessible name and tooltip
  saying so ("Runs, narrowed to acme/shop",
  "Network access, narrowed to acme/shop"). Nothing else carries it, and the palette's Go
  to never does.
- **The sidebar folds to icons** from 768 px, by the fold (`#sidebar-collapse`, an icon
  button named Collapse sidebar, or Expand sidebar while folded, in its label and its
  tooltip) or the `[` key; the fold is a reading preference in `localStorage`, set before
  the first paint by the root layout's script, and while folded each item's name is its
  title. Folded, the foot is the fold over the mark alone, which still opens the menu,
  upward and to the right; the groups are split by rules, their headings gone.
- **Below 768 px the sidebar is a drawer** behind the bar's Open menu button, its head, where
  either has a menu (above), the organisation and the workspace, each opening its menu
  where it has one, else its name, then a Close menu button, and its foot the same,
  without the fold. Open, it is a modal dialog
  (`role="dialog"`, `aria-modal`). The `NavDrawer` hook moves focus into the drawer, makes
  the top bar, `#shell-content` and Skip to content inert and stops the page scrolling
  behind it; the scrim, Escape, the Close menu button and any navigation close
  it, and focus returns to the menu button. It scrolls as one piece, its Close menu button
  kept at the top, so on a short screen the foot never squeezes the main entries. Under
  its head it holds the sidebar alone; on a settings page the foot's Workspace settings
  is drawn lighter, the page's parent, while the disclosure under the bar (Two levels,
  above) names the level and lists its sections. The bar names the last segment of the breadcrumb only, and before
  it, on a page under a parent, the parent as a link back, a chevron before its name
  (`‹ Runs / Run 14`): the item of the one
  breadcrumb the wider bar shows too (`q-trail-up`), so a screen reader hears one trail.
  Where the two do not fit, the page's name is cut short first, with an ellipsis, and the
  parent keeps up to 8rem. A section's page shows its name alone. On a core
  Instance page, which has one section and so no disclosure, it keeps both,
  `Instance settings / Configuration`.
- **Landmarks.** A Skip to content link is the first thing in the tab order and targets
  the one `<main id="main">`. A page has one `<h1>`, the title of its header
  (`PageComponents.page_header/1`, or `<.header>`), which also holds a one-line
  description and at most one primary and one default action, or, where the page makes
  two peer kinds (Machines: New machine and New pool), two default actions and no
  primary. Card titles are `<h2>`.
- **Dead ends.** A path under an organisation the person reaches that leads nowhere for
  them is a `404` inside the shell, with the organisation's sidebar
  (`ApiaryWeb.DeadEnd`): a workspace address that matches no workspace they reach,
  "Workspace not found", "You have no workspace at this address in Acme. Its address
  changes when the workspace is renamed.", and the workspaces of Acme they reach, as
  links; New workspace for a person who may not create one, "New workspace" with no kind
  cards and one line: where the organisation has as many workspaces as the edition allows,
  the limit's line in an information notice, as the owner sees it there, since nobody
  creates another; else who creates workspaces.
  A workspace they do not reach gets the same page as an address that matches none. An
  organisation they do not reach is the plain `404`, "Not Found".
- **A work item's permanent address.** `/work-items/wi_…`, the link other systems and
  runs get (`Apiary.WorkItems.stable_url/1`), redirects to the work item's page,
  `/:org/:workspace/work/:number`, at the organisation's and the workspace's addresses
  when the link is followed, without the query. A visitor signs in first, whatever the
  id, and then comes back to it. A person who may not open the work item gets the plain
  `404`, "Not Found", the same as for an unknown or malformed id: a dead end would list
  the organisation's workspaces.

## No modals

Nothing opens over a page but **Search or jump to**, the palette (above), and the
confirmation before an act that spends (below). Every other act happens on a page, in
place:

- **An act that spends is confirmed in a dialog over the page** (`ApiaryWeb.SpendDialog`):
  each act that starts a run, which uses a machine and model tokens, or a build machine.
  Its title is the act's name as a question ("Run another round?"), then one line on what
  starts ("Starts a run of `explore-a-ticket` on a machine of build-eu. The run uses
  model tokens."), the act's fields where it has them, such as its note, and Cancel with
  the act's name. Focus goes to Cancel, not to the act's button, so an Enter held down
  on the button that opened the dialog starts nothing. For a dialog whose first focus
  belongs on a field, set `focus` on `ApiaryWeb.SpendDialog.frame/1` to the field's id.
  Use a textarea or another control where Enter does not submit: Enter in a single-line
  input confirms the spend. Focus stays in the dialog; Cancel, Escape and a click outside
  close it, change nothing and keep what was typed on the page, and focus goes back to
  the button that opened it. An act that starts a run only in some states (Confirm,
  Approve, Request changes, Accept as it is, Move back, Check again, Add version) opens
  the dialog only where it starts one, and acts at once otherwise.

- **A form is a page** of its section at a separate path, never a dialog over a list:
  Invite people, New machine, a policy's New rule and Edit rule,
  an export. Its
  breadcrumb ends with the section and the page; its title is the act and what it acts
  on, with one sentence under it; its form fills the 720 px column, its first field takes
  the focus, and its foot is the primary button with Cancel back to where it was opened
  from (`SettingsComponents.save/1`, `cancel`). Its header has no Back link: Cancel and
  the breadcrumb lead back (`PageComponents.page_form/1`, `page_form_foot/1`). A step of
  the set-up has Back at its foot instead (The set-up, below). A save goes back with a
  flash; a refused one stays, the error under its field. What a save shows once,
  such as a generated key's secret, it shows on the page the save leads to, never again
  once the reader leaves it.
  A settings page whose form needs context has a column beside the form, **About this
  page** (`PageComponents.context_column/1`, the `context` slot of `settings_page/1` and
  `SettingsComponents.layout/1`): why the page exists, what it changes, and the steps the
  reader takes outside it, never a field, an option or a button the form shows. It is
  300 px wide beside the form once the section has 840 px for both (from a 1366 px screen
  with the sidebar and the second column open), the form keeping up to 720 px, and under
  the form below that; in reading order it comes after the form.
  A form is a page, under Settings, says the rest.
- **A confirmation is in place** (`<.inline_confirm>`, Components): a row's Delete,
  Revoke, Remove, Suspend or Clear turns that row into the question, what is lost,
  "Yes, delete" and Cancel; a danger zone's line expands
  under its sentence, with the field to type where one is asked; a setting on the page,
  such as the policy's mode, opens its choices in place and asks under them. Each keeps
  the path it had, which opens the page with that confirmation showing and never acts by
  itself; Cancel and Escape go back.
- **What is undone as easily as it is done acts at once**, with a flash that says what it
  did: a plain Remove of a policy rule. It asks in place
  only when something is lost or set aside.
- **What only reads** is a page too, or opens in place under its row: the keys of the
  policy pages (`?`).
- **Menus, Filter, the switcher and Jump to date** drop down under their button: a
  disclosure, its button's `aria-expanded` and `aria-controls`, its panel a menu or a
  named group, closed by Escape or a click elsewhere. They are no dialog either.

## Settings

Configuration is not navigation: what is set up once and changed rarely lives in the
settings. There are five kinds, on the model of GitHub's repository, organisation and
personal settings: a workspace's, an organisation's, a machine's, a person's and the
instance's. Each is a separate place, reached from its scope, that lists its sections
and no other kind's: no "Elsewhere", no link across. A navigation item never
replaces the navigation it is in.

- **A workspace's** (`/:org/:workspace/settings/…`), from the workspace sidebar's
  Workspace settings: General (name, slug, and its danger zone), People (`/settings/people`,
  `ApiaryWeb.MemberLive.Workspace`: who reaches the workspace and at what level, read
  only, on the row spec of the organisation's People, the edition's `:member_access`
  beside each name; no suspended membership, which reaches nothing),
  and Runs (`/settings/runs`: how long the workspace keeps runs, their events and their
  logs; `/settings/retention`, its path before, sends on with its query). A workspace's
  keys are its machines' and pools' (Machines, below): `/settings/keys` and `/:org/:workspace/keys`,
  the paths of the Access keys page that was removed, are unknown paths, 404.
- **An organisation's** (`/:org/settings/…`), from the organisation's pages (the
  breadcrumb's organisation leads to its overview, whose sidebar has Organisation
  settings): General
  (name, slug, owners, and its danger zone; the slug is text under the name, follows the
  name, and once the name typed changes it, a warning says which addresses stop
  working; saving opens the page at the new address), People (`/settings/people`: members,
  found by their email with Find a person, `?q=`; invitations, suspensions; Invite
  people, the section's action, is a page of it at `/settings/people/invite` (A form is a
  page, below), its one field the email address, and a sent invitation goes back to
  People with a flash; without mail its button is Create invitation link, and the link
  shows once in place of the form (`one_time_link/1`: "Copy this link and send it to
  dana@example.com yourself.", the link with an icon Copy, "Works once, until 17 Oct,
  14:05 (7 days). It is shown only now.", Done back to People), and a pending
  invitation's ⋯ menu has Make a new link, whose link its row shows in place of its
  cells, once, with Done; removing, leaving and suspending, each from a member's ⋯ menu, are
  confirmed in place, the member's row turned into the question, what happens, Yes,
  remove (Yes, leave, Yes, suspend) and Cancel (`inline_confirm/1`), at their paths
  `/settings/people/:id/remove` and `…/suspend`, whose Cancel or Escape goes back to
  People; on the instance's organisation, while no mail is set, an instance admin's ⋯
  menu of each other member has Make a password link, which, after a recent sign-in (an
  older one leads to the log-in page first), shows the link once above the list, to copy
  and send, until Done, and the link's page, `/users/password/:token`, sets
  the account's password), Workspaces
  (whoever may rename or delete a workspace, `Apiary.Organisations.lists_workspaces?/1`,
  owners and admins in the core; Delete… and the note under the list only for whoever
  may delete one; each with its address beside its name, `/acme/payments`, and its targets, `Apiary.Targets.count_by_workspace/1`;
  `SettingsComponents.workspace_list/1`, which an edition's page over the same list
  renders too, with the edition's way of adding one in the section's actions, the
  `:workspaces_heading` slot; with no workspace in use, one line, "Acme has no workspace
  yet.", and a link to the overview, which shows the kind cards to whoever may create
  the first workspace and who creates it to anyone else), and the
  edition's sections
  (`ApiaryWeb.Edition.settings_tabs/1`). The audit log is not a section of them: it is a
  page of the organisation's sidebar, beside its overview (`/:org/audit-log`,
  `ApiaryWeb.ActivityLive`; `/:org/settings/audit-log` and `/:org/activity`, its paths
  before, send on with their query). From a workspace the palette's Go to, New ›
  Invite people and, for whoever manages members, the workspace People's Manage people
  lead there too, since membership is the organisation's; nothing else in a workspace
  does.
- **A machine's** (`/:org/:workspace/machines/:node_id/settings`), the last tab of the
  machine's page (Machines, below): General (name, kind, a pool's machine limit, and its
  danger zone). The page's header is the machine's, so the section list and the section sit under the
  tabs without a separate heading (`SettingsComponents.layout/1`, `kind={:node}`,
  given its `sections`): the list is in the page, never a second column.
- **A person's** (`/users/settings`, `/users/settings/preferences`,
  `/users/organisations`), from the account menu's Settings: Account (email,
  password, and its danger zone), Preferences (language and time zone, kept with the
  account; the theme, the account menu's, and the keyboard shortcuts, reading preferences
  of the browser), Organisations. Each is a settings page (`PageComponents.settings_page/1`),
  its `<h1>` its section's title; the sidebar stays the one the person came from, and the sections are
  its second column (`#nav-group-account`, `nav-<key>`); with no workspace to show, the
  sidebar is the person's, and lists them itself. Account and the account's deletion ask
  for a recent sign-in (`UserAuth`'s sudo mode); Preferences does not.
- **The instance's**, Instance settings (`/instance/…`, the routes of
  `ApiaryWeb.Routes.instance_routes/2`, each page with `place={:instance}`), from the Qory
  Apiary menu's Instance settings, shown only when the person may open a section of it
  (`ApiaryWeb.Layouts.instance_sections/1`) and leading to the first, as `/instance`
  itself does. For the instance's admins the core's General comes first
  (`/instance/general`, `ApiaryWeb.InstanceLive.General`, its `<h1>` General): one field,
  Name, the product's name on the instance (`Apiary.ProductName`), its placeholder and its
  hint's "Empty: …" the edition's name (`Apiary.ProductName.edition_name/0`), which the
  menu's button shows where no name is set, while titles, log-in pages and emails show
  Qory Apiary there; and under Save, where the edition says "Powered by Qory Apiary", the
  note of when it does. Saving reloads the page with the toast "Instance renamed to …"; a
  name breaking an organisation's name's rules shows its error under the field. Then the
  edition's sections (`ApiaryWeb.Edition.instance_sections/1`), then the
  core's Mail (`/instance/mail`, `ApiaryWeb.InstanceLive.Mail`), the mail server, after a
  recent sign-in, and Configuration (`/instance/configuration`,
  `ApiaryWeb.InstanceLive.Configuration`, its `<h1>` Configuration): the instance's
  settings. Retention, Deletion and Invitations are each a form with its Save: a field for
  each setting the environment does not set, with its unit, days, where it has one, and the
  hint "Empty: …", saved after a recent sign-in with a toast; a setting the environment
  sets shows read only, with the variable that sets it. Then the edition's parts
  (`c:ApiaryWeb.Edition.configuration_parts/1`). Features and Run pruning are read only.
  Anyone else is answered not found. The sidebar stays the one
  the person came from, and the sections are the second column (`#instance-tabs`,
  `instance-tab-<key>`).
- **Instance settings › Machine types** (`/instance/machine-types`,
  `ApiaryWeb.InstanceLive.MachineTypes`, with the feature `factory`, after Nodes) lists
  the instance's machine types (`Apiary.MachineTypes`) for its admins: Name, with the key
  and the badge Default on the default under it; Spec, "2 vCPUs, 4 GiB" over "30 GiB
  disk, amd64" (", virtualization" after a type that has it); Used by
  ("3 workflows", the workflow entries that run on it, in each workspace's current and
  trial process and in each workspace type's newest one, as a deletion counts them; an
  entry set to `default` runs on the default), and Pools, the pools that serve it, "None"
  for none. A pool with offers in its latest claim serves the types that one of them
  fits; a pool without serves the default, and takes the runs of the default type and
  the runs queued on the type that was the default then. The row menu has Edit, Make
  default (not on the default) and Delete…, confirmed in the row: "Delete Large?" and
  "Workflows can no longer pick this type. You cannot undo this." **Add machine type**
  (`…/new`) and Edit (`…/:key/edit`, "Edit Browser tests" in the breadcrumb) open the
  form: Name, Key, vCPUs and Memory (GiB), Disk (GiB) and Architecture,
  Needs virtualization and Default, each with its hint, then the line on how a pool picks
  a machine, and Add or Save beside Cancel. A field's refusal is under it, such as
  "Choose another key: default means the default type.", "Write a name of 1 to 100
  characters on one line, with no tabs.", "Choose another name: Browser tests exists."
  or, while a pool has offers, "No pool offers a machine that fits this type." under
  vCPUs. On Edit, a changed key makes Save show a warning in place of the buttons
  (`#machine-type-key-warning`): "Changing the key breaks every file that uses browser.",
  the counts Qory Apiary updates, the `process.yaml` files to fix, and **Change key** and
  **Cancel**. The counts, such as "Qory Apiary updates 3 workspaces, 2 workspace types, 1
  waiting run.", leave out a workspace type whose newest process is a copy of the Qory
  harness's: the key change keeps that copy, and its runs start on the default type until
  the harness changes the key. The files are those the current and trial processes that
  use the key were read from, where the version read from the file uses the key too, and
  the Qory harness's where a workspace type's copy of it uses the key. Under "Fix these
  files yourself:", each file of the Qory harness has a line with its repository, its path
  (its module for a commit whose files are not kept) and its commit. Under "Organisations
  fix the files in their harnesses:", each organisation has one line with the number of
  its files, such as "2 files in Acme's harness". No workspace name, workflow name or
  repository address of an organisation is on the warning. After **Change key**, the list
  shows the name, the key and the files to fix in the same lines, in a message at the
  bottom right (`#machine-type-key-saved`) until **Dismiss**. Where a
  workspace type is saved at the same moment, the key change saves nothing, and the form
  stays with the toast "Change the key again. A workspace type was saved at the same
  moment, so the key change was not saved." A deletion that fails leaves a line under the
  table: the default, or how many workflows in how many organisations use the type, how
  many workspaces in how many organisations have it as their default machine type, and
  the names of the instance's workspace types that use it, such as "Large cannot be
  deleted: 4 workflows in 2 organisations use it, 1 workspace in 1 organisation has it as
  its default machine type, and the workspace type Software factory uses it." A change
  needs a recent
  sign-in, and the page leads to the log-in page otherwise; anyone else gets a page not
  found.
- **Organisation settings › Model providers** (`/:org/settings/model-providers`,
  `ApiaryWeb.ProviderLive.Index`, with the features `factory` and `secrets`) lists the
  organisation's model providers. Its Keys column has how many keys each provider has
  and how many of them are in cooldown, "3 keys, 1 in cooldown", or "3 keys" while none
  is (`Apiary.ModelKeys.cooldown_counts/2`). A provider's page
  (`…/model-providers/:provider_id`, `ApiaryWeb.ProviderLive.Show`) lists its keys, the
  default key first, then in the order they were added. Each row has the key's name in
  mono and its state on one line (`ApiaryWeb.ModelKeyComponents.state_line/1`), in the
  reader's time zone: "Available", then, each after a middle dot, one segment for each
  limit window with a use or a reset still to come, "Available · 5-hour 89%, resets
  14:00 · 7-day 40%, resets Mon 09:00"; or, while a window of the key has a cooldown
  that ends later, "In cooldown until Fri 14:00", the latest such end, and after a middle
  dot where that time comes from: "from the provider's response", "from this key's
  schedule", or "no reset time given; paused for 1 hour", the cooldown that applied, from
  the response that started it to its end, whatever the key's Pause for is now. A time is
  the time of day alone on the reader's day, the weekday and the time on one of the six
  days after it, else the date and the time (`ApiaryWeb.Format.week_time/2`). The windows
  read 5-hour, 7-day, 7-day Opus, 7-day Sonnet, Extra usage, Requests per minute, Tokens
  per minute, Input tokens per minute, Output tokens per minute, Spend limit and Limit;
  a window of another code shows its code. The page shows no key and no part of one.
  Every member reads it (`connection.read`); owners and admins (`provider.write`) have
  **Add key** in the section's actions and **Edit** at the right of each row, its label
  "Edit key main", and anyone else neither.
- **Add key** (`…/model-providers/:provider_id/keys/new`) and **Edit key**
  (`…/keys/:value_id/edit`), `ApiaryWeb.ProviderLive.Key`, are pages (A form is a page,
  below), the breadcrumb ending with the provider's name and the act. The form has Name
  ("Lowercase letters, digits, ., _ and -."); Key, on Add key alone, a password field
  that is empty after every save, with "Qory Apiary stores the key encrypted, and nobody
  can view it again."; then Resets and Pause for
  (`ApiaryWeb.ModelKeyComponents.settings_fields/1`). Resets is a group of Day, Time and
  Time zone, whose zone is the reader's for a key with no reset, with the hint "The
  weekly time when this key's allowance resets. Set it if the provider sends no reset
  time." Pause for is a number and a unit, minutes, hours or days, with the hint
  "How long runs skip this key after the provider returns a limit error, when no reset
  time is known. Empty: 1 hour." for a subscription's key, and "Empty: 1 minute." at its
  end for an API key. A group's error takes its hint's place: "Set the day, the time and
  the time zone, or leave all three empty." and "Enter a time from 1 minute to 7 days."
  The foot has Add key or Save beside Cancel. A save goes back to the provider's page
  with "main is added." or "main is saved."; a name another key of the provider has
  shows "Another key of Northwind Claude has this name." under Name, and a key past the
  32nd "Northwind Claude has 32 keys, the most it can have. Delete a key to add
  another." under Key. Add key of a subscription has About model providers beside the
  form. Workspace settings › Secrets and variables has the same Resets and Pause for on
  Add value and Change value of a model provider's key. Change value with New value
  empty saves Resets and Pause for and keeps the key's value.
- **Workspace settings › Model** (`/settings/model`, `ApiaryWeb.ModelChoiceLive`) has the
  part Fallbacks (`#model-fallbacks`) under Runtime, Model and Effort: the line "When
  every key of Northwind Claude is in cooldown, runs use these, in order, from the next
  run.", then one row for each fallback, in order, from the second on with a rule above
  it. A row is a group named by its place, "Fallback 2", with Provider, Model, Another
  model and Effort as the choice has them, then Move up, Move down and Remove, each
  labelled with the place ("Move fallback 2 up"). Add fallback adds a row of the first
  provider left: one that applies to the workspace, serves the chosen runtime, and is
  neither the chosen provider nor in a row. A new row's model, and a row's model after
  its provider changes, is the chosen model where the provider has a model of that id,
  else the provider's first. With no provider left, the part shows "Add another model
  provider that serves Claude Code in Organisation settings › Model providers, then add
  it here as a fallback.", the place a link. Save writes the rows with the choice, and an
  error shows under its row's field, such as "Choose another provider: Northwind Claude
  is chosen already." A save that sends no rows, as the set-up's Model step saves, keeps
  the rows but one of the chosen provider, which it drops. A save that changes the chosen
  provider to the provider of a row drops that row.

A workspace's and an organisation's settings keep the scope's sidebar, its Workspace
settings or Organisation settings the current entry, marked as the parent, and are one
section a page (`ApiaryWeb.SettingsComponents.layout/1`, or
`ApiaryWeb.PageComponents.settings_page/1`): the section's title is the page's one `<h1>`
(20 px, `#settings-section-title`; `heading`, the level's h1 before, is ignored), one
sentence of what it is for, then its content; the frame names the level, in the second
column's heading, the breadcrumb and the browser title. Content is a 720 px column for
forms and 960 px for a list (People, a workspace's and an organisation's).
The list of the kind's sections is not in the page but the frame's second column (Two
levels, under The shell; `#settings-tabs`, `settings-tab-<key>`): the page reads them when
it mounts (`sections/2`) and passes them to `Layouts.app/1` as `sections`, the page's key as
`section`. It is labels without icons, muted, the current one in the text colour on a
light fill, with a count where it helps (an organisation's People, from the navigation's
`counts`); below 1024 px it is the disclosure under the top bar (Two levels,
under The shell). A section is flat, no card: its fields straight under its heading
(`SettingsComponents.part/1`, an `<h2>` where it has more than one part, such as Owners;
the danger zone's lines are `<h3>`s), the fields as wide as the column, and at the foot of
a form its one button, primary where it is the section's main action, beside one muted
line (`SettingsComponents.save/1`). A section the reader may not open is not in the list,
and its path sends them to General with the section's sentence of why.
The breadcrumb names the level and ends with the section, both written by the frame
(`Acme / Main / Workspace settings / Runs`, `Acme / Organisation settings / People`);
a person's page starts with Your settings and an Instance page with Instance
settings, then the section (The top bar, under The shell). The browser title is the most
specific first, the page's words, the level, then the workspace's name and the organisation's
(`SettingsComponents.page_title/3`), then the product's name on the instance
(`Apiary.ProductName.name/0`, the root layout's): `Runs · Workspace settings · Main ·
Acme · Qory Apiary`, `People · Organisation settings · Acme · Qory Apiary`, `Account ·
Your settings · Qory Apiary`, `General · Instance settings · Qory Apiary`; with the name
Acme Agents set, `General · Instance settings · Acme Agents`.

**A form is a page.** Creating or changing one thing is a page of its section at a separate
path, never a dialog over the list: the second column stays beside it, its section the
current one, marked as the
parent (`aria-current="true"`); the breadcrumb ends with the section and the page, each
segment before the page a link back, the page adding only the segments after the
section; the section's `<h1>` is the page's title, the act and what it acts on, with one
sentence under it of what the page does; the form fills the 720 px column, its first field
takes the focus, and its foot is the primary button with Cancel beside it, a link back to
the list (`SettingsComponents.save/1`, `cancel`). A save goes back to the list with a
flash; a refused one stays on the page, the error under its field. The breadcrumb's last
segment is the act alone, and the browser's title the page's.

**The danger zone** ends its scope's General page, and Account, GitHub's way
(`SettingsComponents.danger_zone/1`): after a rule, the heading Danger zone, the page's
only red words, then a line for each act that cannot be undone (`danger_action/1`), its
title, one muted sentence of what it does and what cannot be undone, and at the right a
default button in the error colour, Delete organisation…, Delete workspace… or Delete
account…. No box, and never an entry of a list. **Its confirmation is inline, never a
dialog**: the button is a patch to the act's path, `/:org/settings/danger`,
`/:org/:workspace/settings/danger`, `/users/settings/delete` and a machine's
`/machines/:node_id/settings/delete` (the older `/…/settings/delete` paths open the same),
and there the line expands in place under its sentence
(`SettingsComponents.deletion_confirm/1`), set apart by a rule in the error colour at its
left: what is lost, the field asked to confirm where there is one (the slug, or for the
account its email), then the question, Delete Acme?, with its red button, Yes, delete,
disabled until the field matches, and Cancel beside it (`<.inline_confirm>`). The field
takes the focus, or Cancel where there is none to type (a machine's); the line's button
then folds it (`aria-expanded`), and Cancel and Escape, a patch back to the page, give
that button the focus back. Where the act is not there, the line says why in place of the
button: the instance's organisation, the organisation's only workspace; where
something stops it for now, the button is disabled and the page says what under the line
(the organisations a person is the only owner of). A reader who may not delete the scope
sees no danger zone, and the act's path sends them to General and says why.

Deleting any workspace from Workspaces is confirmed the same way in its row
(`/:org/settings/workspaces/:workspace_id/delete`): the row shows the confirmation in
place of its cells, its slug typed to enable Yes, delete, and Cancel gives the row back.
Every other act on a row of a list (revoke, remove, suspend, a deletion) is
confirmed on its row too, each at a separate path (No modals, above).
The old paths, `/:org/members/…` and `/:org/:workspace/settings/retention`, send on to
the new ones
(`ApiaryWeb.MovedController`).

An organisation's path, `/:org`, is its overview (`ApiaryWeb.OrganisationLive`): the
workspaces the person reaches, what each is doing, and the organisation's people and
details, its address the path `/<org>` as Organisation settings shows it; once the
organisation has a workspace, its header's actions are the edition's (the
`:organisation_heading` slot), such as a way to add a workspace. The breadcrumb's organisation leads there; `/` still sends a person to the workspace they
opened last.

## Lists

A page that lists things reads top down, and every level of it has a distinct look: a
summary, the largest numbers on the page, only where the page has one; then blocks or
tables, each one box; then rows. Two levels that look alike are one level too many, and
nothing is boxed inside a row.

- **A row is one line.** Its title, the thing's name, is the only strong text: 14 px,
  medium, in the text colour. Every other cell is 12.5 px and muted; what is tertiary is
  faint; the one fact that needs someone is lifted to the text colour (`q-hot`). `<.table>`
  does this by default: a column says `kind="title"`, `"hot"`, `"faint"` or `"num"`, and a
  secondary word beside the title (an id, a slug, "you") takes `q-side`. A row out of use
  (revoked, suspended) is `row-off`, its title muted.
- **A state is said only when it is not the usual one.** An active key, a member in use,
  a run that completed say nothing (a screen reader hears the word); a suspended
  member, a revoked key say so in words (`<.state_word>`), with a dot and the
  text colour when the state needs someone. A pill is for a state of at most two words
  that needs someone, and never on every row.
- **A row's acts.** The one act its state asks for is a text action (`<.button
  variant="link">`); the rest are in its ⋯ menu
  (`<.row_menu>` with `<.menu_item>`s, a heading and dividers between groups), which
  floats in the top layer so the table's scroll region never clips it. A choice of one,
  such as a person's level, is a set of `menuitemradio` items with what each means. A
  destructive item asks on its row, at a separate path (No modals, above); red is for
  that confirmation's button only. No bordered button on every row. Network access is
  the exception: Allow and Deny are icons and the row has no ⋯ menu (Lists, A
  destination).
- **Columns grow with the table**, not the screen: `from="sm" | "md" | "lg"` shows a
  column from 600, 1000 or 1300 px of the table's width (a container query), so a
  table in a narrow pane reflows as it would on a narrow screen.
- **A target** is its path in mono, with its system in faint type before it only where the
  same path is on more than one system (`<.target_name>`, `Apiary.Runs.shared_paths/2`).
- **One way to narrow a list**: views as tabs with their counts (`<.views>`), one search
  (`<.list_search>`), one Filter menu whose sections write the filters
  (`<.filter_menu>`), Sort (`<.sort_menu>`, its button naming the order in force:
  Newest, Denied first), the query field in mono, and the filters in force as removable tokens
  under the bar (`<.filter_tokens>`). Every choice is in the URL. No row of facet buttons;
  a rail never repeats a menu.

### The runs list and Network access

A long record is narrowed by filters written in the URL, never folded into groups the
reader has to open. The runs list (`ApiaryWeb.RunLive.Index`) and the workspace's Network
access (`ApiaryWeb.ConnectionLive.Index`, `/:org/:workspace/network`: every destination
the runs reached, what decided it, and the way to allow or deny it) are one flat list
each, and `Apiary.Runs.Filters` reads and writes every control of them. The page was
Connections: `/:org/:workspace/connections` and a run's `/runs/:run_id/connections` send
on to the new paths with their query, moved permanently (`ApiaryWeb.MovedController`). A
connection as a thing keeps its word: a row is a destination and the connections made to
it. The Policy page's hosts and paths are its Network access section, which links to the
page ("See what the runs reached"); the page's rule links lead to the rule there.
Network access also lists the harness fetches in a separate locked table
(`ApiaryWeb.HostComponents`), outside its counts, views, facets and rule options.

A target is filtered by the id Qory Apiary gives it, never by its system or its path:
`?target=tg_…`, several ids joined by commas for the runs of any of them, and
`?target=none` for the runs with no target. The ids are read with the address, in one
query scoped to the workspace (`ApiaryWeb.Narrowing`): an id that names no target of the
workspace is dropped, like any value the page does not know, and the page says the link's
target filter could not be read. An address of an older release, which named a target by
`system=` and a path in `target=`, is dropped the same way. A typed `repo:` takes a
target's name, or its id. A name that names no target is search text, never an address: it
stays in the query (`?q=target:acme/nowhere`), the list matches nothing (no run on Runs, no
destination on Network access), and the line names it as typed ("Showing the runs of
acme/nowhere only.", "Showing acme/nowhere only."). A target chosen in its place, in the
Filter menu or the rail, takes the name out of the query and keeps the rest of the text.

The policy's lists of rules (`PolicyComponents.rule_list/1`, on the workspace's Rules tab
and on a target's Policy tab) are on the same pattern, their query read and written by
`ApiaryWeb.PolicyLive.RuleList`, pure over the rows the page holds: views All, Allowed,
Denied and Locked, each counted under the search and the other filters, the Rules tab's
count the All view's with nothing narrowed; "Find a host" with the qualifiers `seen:`, `paths:`, `by:` and
`source:` as tokens, sent as the reader types and read whole on Enter; one Filter menu
whose sections come from the rows' sources and people (an edition that adds rules of
another holder gives them a source, and the menu, the qualifier and the order take it);
Sort (the default order, Host, Most used, Recently added); pages of 50; and `?rule=`,
which Network access links with, landing on the page that holds the rule and marking it.
The list is the Network access section of its page: its header holds the heading, how
many rules, "See what the runs reached" and **Add rule**, the section's one primary
button, with a line under it of what the rules are; the search's bar keeps Find, Filter
and Sort. A reader who may not change the policy sees no Add rule and no row menus.

**A rule is added and changed on a page** (No modals, above), never in a line
over the list: New rule (`…/policy/rules/new`, a target's `…/tg_…/policy/rules/new`) from
Add rule, the empty list's Add a host rule and the top bar's New (Network access rule);
Edit rule (`…/policy/rules/:id/edit`) from a row's ⋯ Edit, for an allow and a deny alike
(`PolicyComponents.rule_form/1`). The form asks the goal first: "What should runs do?",
Allow and Deny as two radio cards that each say what they do; then Host, labelled with
its help under it; then "What this rule does", the rule read back in plain words as it
is typed (`PolicyLive.Reading`), a polite live region. An error is said under its field,
with its repair as a link (Use api.example, Show it); a refusal, a lock's or the
domain's, takes the read back's place above the foot. Add rule is never off: pressed
with an error, it moves the focus to the first field at fault. A pasted list of hosts
fills Host with the first and counts the rest beside its label; each is added in turn,
the page staying until the last.
A save goes back to the list as it was left, on the page that holds the rule, its row
marked and New in its version, the focus on its ⋯, with the flash that names the version;
Cancel goes back to the list as it was left. On Edit rule the host is shown, not a field:
another host is a new rule.
A target's Policy tab shows each rule's Source; the target rules come first and have the ⋯
menu's acts, the workspace's are read there and lead to the workspace's page. A rule of
the level above the workspace has that level's tile in its Source, which says whose it is;
the faint lock is a locked rule of the workspace's alone, what the Locked view counts.
The mode is a card above the tabs, the same on the workspace's Policy page, on each of
its tabs, the Document tab included, and on a target's Policy tab, above each of its
views (`PolicyComponents.mode_card/1`); a version opened from the History (the one in
force too) and the export, which state their mode, have none. It states the mode in
force: a honey tile with the mode's icon (a lock where a level above requires enforce),
"Mode: Enforce" as its heading, whose it is as a badge (Workspace default; Follows the
workspace, by its name, or Overridden; Required by the level), one sentence of what the mode
does and who follows it, and on the workspace's the record of the last 14 days with its
link. A member sees the card with no Change mode and the line that says who may.
The Document tab (`…/policy/document`, a target's `…/tg_…/policy/document`) is the document
in force under the card and the tabs: its version's number, In force and the version's
views, which stay on the tab. The document's bar is the tab's one place to take it away,
the code-block header's pattern: two small icon buttons on its right, Copy (the document
as served; its hint reads Copied while the copy is confirmed, which is said politely
too) and Download (the document as served, the bytes Copy copies, saved as
run-configuration.json; the export page's policy file stays on the export page), each
named by its hint, which opens under it, flush with its right edge. The tab has no Export;
the export page opens from the header's Export on the other tabs and from a version's
page. In the list of versions, on the tab and on each
version's page, the version in force leads to the Document tab and an older one to its
page. A change that makes a new version, Enforce or
Observe among them, shows the new version, its number and its mode there in place. A
target served the workspace's policy shows the workspace's version: in its list the
version in force leads to the target's Document view and the older ones to the
workspace's version pages, and Download saves the workspace's document.

The policy pages confirm in place, never over the page:

- **A mode** is chosen, then confirmed, never switched at once. Change mode opens the
  choices in the card (`?confirm=enforce` lands with them open and Enforce picked): one
  option card per mode (Follow the workspace first on a target), each a native radio with
  what it does, the mode now marked Current. A pick only selects. A pick that is not the
  mode now asks under the options: the question, what it does and in whose runs (or that
  nothing changes today, and what changes from now on), for enforce what the last 14 days let
  through with no rule, each with its Allow; then one primary button that names the pick
  and Cancel. Escape, with the focus in the choices, cancels (the `PolicyPage` hook);
  saving or cancelling gives the focus back to Change mode, and the save is said in the
  page's status region. The choices stay open on another tab.
- **A rule's row** asks for its acts where they cost something: a Lock that would put
  a target rule out of force, and the Remove of a locked rule or of one a target
  overrides. The row becomes its `inline_confirm/1` (`rule_list/1`'s `confirming`): the
  question, what follows, Yes, lock or Yes, remove, and Cancel, which gives the focus back
  to the row's ⋯. A plain Remove, a Lock that holds nothing back and Unlock act at once
  and say so.
- **The keys**: `?` shows and hides the list of the page's keys, a panel at the top of
  the page (`#policy-keys`), not an overlay; Escape and its Close hide it.

**The export** (`…/policy/versions/:n/export`, and a target's
`…/tg_…/policy/versions/:n/export`) is a page, not a dialog: the top bar's breadcrumb ends
with Version n and Export and is the one way back, with no separate trail on the page; the
title "Export for a machine without a server" and what is exported (an h2 under a target's
title), the policy file with Download and Copy, the command for the
machine and the Forager file's egress section, each with Copy, the notes, and Done back to the
Document tab (a target's Document view), the version in force under the card. Only the
version in force is exported; another version's path sends on to it.

- **Views** are the runs list's All, Alive, Ended badly and With denials, and Network
  access's decisions, each counted under every other filter; All is current when no other
  is. Ended badly counts the runs that failed or were lost. The Filter menu's State
  section lists the seven states and Queued under their five families, each heading a
  checkbox for the whole family: Alive (Queued, Pending, Running), Ended well
  (Completed), Cancelled (Cancelled), Paused (Paused) and Ended badly (Failed, Lost).
  Queued is a pending run that waits in the queue for a machine
  (`Apiary.Runs.Run.queued?/1`): it has its run record and its number from the moment it
  is queued (`Apiary.Dispatches.Queued`), with no node and no registration; Pending is
  any other pending run. Newest first, the queued runs come first, newest queued first,
  then the rest. A queued run's row has the badge Queued with a hollow dot, its work
  item, its workflow and who started it, Started its queue time and Duration n/a. Alive
  and the sidebar's count of runs alive count the queued runs, and the list follows a run
  queued, claimed or ended while it waits, without a reload. A cancelled or paused run
  counts neither as ended well nor as ended badly. A filter of whole families shows their
  words ("ended badly"), and an empty list of one family shows that ("No runs
  cancelled.", "No runs paused."). A run stored under a state's older name counts and
  lists as its new state. A view's filter is not repeated as a token. The number that
  matches is a line over the list, only when the list is narrowed ("87 runs match"), in
  the list's status region (`role="status"`, `.q-status`), which is always rendered,
  empty and taking no place otherwise, so a screen reader hears what a view, a filter or
  a search left; while the list is empty, the region contains the empty state's title.
- **The search is a query** (`<.list_search live={false}>`, sent on Enter): qualifiers
  (`repo:`, `state:`, `runtime:`, `host:`, `machine:` (or `node:`), `machine-type:large`
  (the runs queued on that machine type), `item:3` (a work item's number, `item:#3` too), `started:>2026-09-01`, `denied:yes`;
  `decision:`, `tools:`, `seen:` on Network access) become the URL's parameters and show
  as tokens, and the other words are the free text, `q`, matched as text without regard to
  case (a run's id, title or target; a destination's host or path). A run's id is the start
  of its `rn_` id, four characters after `rn_` at least, or of the run id on the machine, four
  hexadecimal characters at least; a run page's address finds that run. `state:` takes a
  state or a family (`state:completed`, `state:queued`, `state:ended_badly`). A word it cannot read is said in a notice, never dropped in silence. On Network
  access the field suggests the hosts in the list as one types (a combobox, at most 8,
  from the host filter's query, narrowed as the list is); choosing one adds `host:`.
- **The Filter menu has sections** (`<.filter_menu>` with `section`s): too many values for
  a menu, each section searches its values on the server over every value there is,
  fifty shown and more on asking, each counted under the other filters
  (`RunComponents.filter_options/1`). The runs list's Work item section lists the work
  items of the runs ("#3 Say hello") and sets `item:`.
- **The rail** (`<.target_rail>`, from 1280 px) holds the targets with their counts under
  every filter but the target, in the list's unit: runs on the runs list ("Most runs"),
  destinations on Network access ("Most destinations"), as its views and its Filter
  menu's Target section count them. A search on the server, every target, the pinned ones
  first under Pinned (`counts.pins`), then the busiest twenty and "n more", the rail's
  headings under an `<h2>` for a screen reader so the outline never skips a level.
  Choosing one sets the target; below 1280 px the Filter menu's Target section does it,
  never both. The runs list shows its rail only where a run under the other filters has
  a target, or where a target is chosen; where every run is unassigned there is no rail.
- **A run is one line** (`<.runs_table>` with `Apiary.Runs.list_facts/2`), in the
  columns State, Run, Workflow, Work item, Started by, Runtime, Started, Duration and
  Denied. The state is a dot and its word for every state, Completed included; Cancelled
  shows its word muted and a grey dot. Run is the run's `rn_` id, the link to its page,
  which covers the row. Workflow is the workflow the claim handed to the machine, in the
  mono font (`explore-a-ticket`, `hello`): the run's harness walk's workflow, only while
  that walk is resolved from the target's harness file, a setting or the built-in
  harness; "Prebuild", muted, for an environment build; "n/a" for any other run (a walk
  pending or failed, a walk that resolved to no workflow, a run queued before walks were
  kept, a direct `qory run`). With the workflow model, the stage that placed the run is a
  muted line under it, "Build", a middle dot and "round 2" inside a loop, the stage alone outside one, only
  where the stage's name is not the workflow's name or its first word (Explore with
  explore-a-ticket has none). Work item is "#3 Say hello", a link to the work item for a
  reader who may read work items; a work item that moved to another workspace shows its
  title alone, with no number, no link and no target; a run with none shows the title the run gave, with what
  it is about (its kind and up to two subjects, as text) muted under it, else "No work
  item". Started by says how the run started: "Taken in by dana", "Taken in again by
  dana", "Attempt 2 of 3, after answers from dana", "Explore again by dana", "Test run by
  dana" (the two take in texts only for the run a take in queued, at the start of the
  first stage),
  "The workspace's process" (any other run the stage runner placed), "Queued again after a missing image", "qory run on a machine" (a run of no
  queue), each person by the short form of their address, "Former member" for one no
  longer there, else "n/a". Target (Repository in a software workspace) shows only where
  a run of the page has a target, from its start's labels, else from its work item in this
  workspace. There
  is no Host column; the Host filter stays, and the Machine or pool column (from 1300 px)
  names the instance's Qory Pool. Where the table is narrow the columns give way in
  this order: Runtime below 1100 px, Target below 1000, Started by below 900, which then
  shows muted under the work item. Below 640 px a run is a card: its id and its workflow
  (the id, a middle dot and `explore-a-ticket`; nothing after the id for "n/a") and its state; its work
  item; when it started and how long it ran; its denials when it has any. Another list of
  runs, such as a machine's recent runs, keeps the line it had: the title, else the id,
  the target after it, what the run is about under it, and Runtime and Host from 1150
  px.
- **A destination is one line** (`<.connections_table>`, `RunComponents.connection_row/1`):
  its host in mono, the port faint and the path muted, the only strong text; its runs and
  attempts muted numbers; allowed and denied a thin split with its two numbers, the denied
  one red only when there is one, and the words for a screen reader; the reason of the last
  attempt one muted line, the rule in mono and nothing bold, whole on hover, a line under
  the destination below 600 px of table. No tint and no decision mark. The host is never
  cut: where the line is short the path goes under it. Columns join as the table widens,
  so nothing is cut at the right: the reason from 600 px, the last seen from 780, the runs
  from 840, the attempts and the outcome from 1300. A run's Network access tab draws the
  same row without the runs, its title the request line, its times the offsets inside the
  run; only the timeline's inline connections keep a glyph. A row's acts are two icons,
  Allow (a check in a circle) and Deny (the deny mark), each with a hint and the host in
  its name, in two fixed slots so they line up: only the one that would change something
  shows, both where no rule decides the host. They show on hover, on focus inside the row
  and while the row's panel is open, always on a touch screen, and at every width. There
  is no ⋯ menu. The host has a copy icon beside it (it copies the host), shown on row
  hover, on the icon's focus and while it says Copied, always on a touch screen. Where the
  rule in force is the one the reason names, its name links to it; where the level above
  decides the row, its "Main · denied" (or allowed) links to that rule; a row a rule was
  just added for ends its after line with Show the rule. A locked rule, the wall, a host
  no rule can name, a deny of the level above, and an allow only the level above can grant
  for a reader who may not change it there, and on Network access and a run's Network
  access tab a runtime's, an integration's or a model provider's host ("Allowed for every
  run") are a faint lock
  whose hint says why (who locked it and when, where known; the wall's reason); a locked
  rule's lock opens its
  refusal in place, with the way to the rule. Where only the level above the workspace
  allows a host, the row's reason says so in words, and Allow opens a panel that says an
  allow here would not be in force and leads to that level's New rule page with the
  host, where the edition gives one, for a reader who may change it there, and with the
  way back to this page (`back`, `c:ApiaryWeb.Edition.above_policy_link/1`); never a
  navigation on the click alone. A
  row opened by its chevron lists the runs that reached it as lines under it, a dot for each state, no box. The
  default order, Denied first, puts the destinations whose last attempt was denied
  first, the most denied attempts first and then the most recently seen, as To
  review weighs them; the rest by when they were first seen, so they hold still.
- **A row's rule is asked for in place** (`RunComponents.rule_panel/1`), never in a
  popover, a dialog or a sheet: Allow, Deny and a locked rule's lock open
  a row of the table right under the row (`#<row>-panel`), in the page's flow, the
  row and its panel in the chosen row's tint. It holds the rule's form, its title ("Deny
  registry.example"), the paths a path rule would change, For (this target, or one target
  of those that reached the host, and the whole workspace, each with what it changes),
  when it takes effect, then its button, which says what it does ("Allow for the
  workspace"), and Cancel; or a locked rule's refusal with Show the locked rule and Close;
  or the way to the level above's policy with Cancel. The trigger says it is open
  (`aria-expanded`, `aria-controls`), never that it opens a dialog. The focus goes into it
  as it opens, on the option chosen (else the first), Close, or the way to the level
  above, and back to the icon that opened it as it goes, or, where it is gone, to the
  row's rule link, its after line's Show the rule, or its copy icon (the `RulePanel`
  hook); Enter sends the form once its button can,
  Escape cancels it wherever the focus is. One panel is open at a time.
- **Pages** of 25, 50 or 100 (`<.pager>`), "1–50 of 3,137", the page before and after named
  by the order (Newer, Older), and Jump to date on the orders by time.
- **The preview** is for 1920 px and more: a pane beside the list, a rule at its left and no
  card, of the run chosen (`?run=`, its number; its `rn_` id is patched to the number, and
  another value is dropped with a notice;
  the first row until the reader chooses one), with the
  last lines of its log as plain text for a reader who may read the log (`run.read_log`;
  without it, no line is read and the preview has no terminal). The `RunList` hook tells
  the page the width, turns a row's click into a choice there, and moves it with ↑ and ↓;
  Enter or a second click opens the run. Below 1920 px a row is a link to its page.
- **Nothing to show** is an empty state with no table and no pages, in words and without
  a tile (`<.empty_state icon={nil}>`): what the filters hide, the last filter to remove
  ("Remove host:gpu-01") and Clear filters.

### Counts and their windows

A number the reader can compare across pages says its window, and the same number comes
from the same query wherever it is shown; where two pages count different things, their
words say so. The workspace's window is **fourteen days**:

- **Network access** reads `seen:14d` unless the reader sets a range, and says it as a
  token like any other (`Apiary.Runs.Filters`); taking it away leaves the widest window,
  `seen:90d`, which is said too and cannot be taken away, since the aggregate is bounded.
  The default window is no filter: the Filter menu does not count it. Its views count
  destinations, and a destination with attempts of both kinds counts in each, which a
  line under the views says when it happens.
- **The overview's summary** counts the chart's fourteen days, in the reader's time zone,
  and each number leads to its list over the same days (`?from=` the first of them; the
  denied attempts to Network access, whose Denied view counts the destinations the summary
  names). **To
  review** weighs the same fourteen days but lists only what is still denied, no rule
  having allowed it since, and its "and n more" says so.
- **The Policy page's** fact on the mode card and the enforce preview read fourteen days,
  so "See them" lands on the same numbers; a rule's use is its last fourteen days.
- **The targets index** counts runs, the share that ended well of those that ended well or
  badly (a cancelled run is in neither), and denied attempts over
  the same fourteen days, each column saying so; a **target's page** counts its denied
  destinations as Network access does (host, port and path), so its card and its Network
  access tab agree.

Elsewhere a window is said where it is used: the runs list has none unless set, a lost
run is listed for seven days, a key is idle after thirty.

## The overviews

The workspace overview (`ApiaryWeb.WorkspaceLive.Overview`, `OverviewComponents`) answers
what needs the reader, then what their agents did, and never grows with the data:

- **The summary**: alive now, runs, runs that ended badly (failed or lost) and denied
  attempts over fourteen days, each a link to the list it counts over the same days.
- **To review**: one line an item, on columns the list holds (each row a subgrid,
  so they line up whatever an act says), its mark, its subject, where it is, the reason
  in a few words (the longer sentence on hover), when, and the one text act that settles
  it; five shown and "and n more". Its Allow is Network access's: the same panel, in
  place inside the item under its subject (`#<item>-panel`), never an overlay, the target
  chosen when only one reached the host, and the focus on the next item's act once the
  rule is written. Where the level above the workspace denies the host, or allows only the
  hosts on its list, no allow here would be in force: the item offers the way to that
  level's rule, or, for a host only that level can allow, its New rule page with the host,
  where the edition gives one, to one who may change it there; and a lock with the reason
  to the rest. A denial no rule can change, the wall's refusal or a host no rule can name,
  has a lock where Allow would be, its hover the hint of its row's lock on Network access.
  A host that every run of the item's targets is allowed, such as a runtime's, has a lock
  with the hint "Allowed for every run".
  A resolved
  item stays, struck, until the next
  navigation; one that arrives is announced (`#overview-announcer`), never inserted above
  what is read. A lost run says how it was lost: "Lost, never posted its exit" when the
  lost-run check marked it, with the tip "Nothing was heard for three heartbeat intervals.
  The run may still be going; the record is not.", and "Lost, stopped responding" or
  "Lost, end not recorded" when its exit said so, with the tip "The run's end was not
  recorded; how it went is not known." It offers Open, its page: Qory Apiary records what
  a run reports and never ends a run it did not start; it starts none today. A run the
  check marked leaves when its start arrives, an exit that does not say it was lost, or a
  heartbeat that counts within three intervals of its arrival (a backlog's old heartbeats
  do not), and then says what became of it ("Completed.", "Failed.", "Cancelled.",
  "Heartbeats resumed."); a run whose exit said it was lost stays. Either leaves when its
  seven days pass.
- **Activity**: runs and denied attempts per day on one day axis, drawn for the width the
  `DaysChart` hook measured, with its table twin a text action away: Day, Runs, Ended
  well, Cancelled, Paused and Denied attempts. A day's column counts every run of the
  day, paused runs included. Its Paused part (`q-col-paused`), at the column's base in
  the hue of a paused run's ring, is the day's share of paused runs of the column's
  height, at least 2 px, but at most 1 px less than the column; only with every run of
  the day paused is it the whole column, its rounded top included. The rest of the
  column sits on it, so the two parts meet and keep the column's outline. While a day of
  the 14 has a paused run, a legend follows the title "Runs per day" in the same line: a
  square in that hue and "paused". A day's tooltip reads "6 runs, 1 paused" for
  a day with a paused run, else "6 runs". Each day is said as its runs, of them how many
  ended well, were cancelled, paused and ended badly (today: alive or ended badly), and
  its denied attempts.
- **Active targets**: the eight with the most runs, each with its last run (a dot, and a
  word unless it completed or is pending), a sparkline of its days and its denials.
- **Guard**: a few lines of key and value, each with a muted detail and one link that
  says what it does: the policy's mode and version, the targets with target rules
  (Review), retention (Change, to Workspace settings › Runs).
- A workspace no run has reached is one box: the steps from a machine to the first run, and a
  panel beside them. At step 1 an owner or admin has New machine, and New pool for one who
  may set a pool's limit too (`node.set_limit`). Step 2 is "Connect it" ("Run one command
  on the machine, or generate a key for a CI or another system."). While it is current, it
  names the newest machine or pool with no active key, its name linking to that one's
  Access key tab. At step 1 the panel explains "Two ways to connect a machine", Generate a
  key in the browser's line ending "… this page shows the key's secret once, and you copy
  it into that system."; at step 2 it asks
  an owner or admin "How do you want to connect build-01?", with the two ways as rows,
  Connect with a command and Generate a key in the browser, a pool's Generate a key in
  the browser first, the buttons Get the command and Generate a key. Get the
  command there makes the command in place, as on the tab: the panel shows the real
  command with Copy, "It works once, until 14:32. This is the only time it is shown." and
  "Waiting for build-01 to run it.", with the notice when the server's address is a
  loopback one. For a machine or pool whose choice leads to a gateway, the tab's notice "Runs of
  build-01 go through the gateway edge-01, at https://edge.example.com." (with "edge-01
  has no active access key, so it isn't connected." while it holds none) shows above the
  command, which carries `--via` and the gateway's URL, and the line on a private
  certificate authority under it, as on the command's page. Generate a key opens the machine's Generate a key page. A member reads who
  connects it, and Go to Machines. At step 3 the panel reads "Listening for the first run.
  build-01 verified 2 min ago." alone. No placeholder command shows anywhere.

An organisation's overview lists its workspaces one line each, six at most and a link to
all, with its people and details as lines beside them; Details has no link to the
settings, which the sidebar's foot, Organisation settings, leads to on the same page. A
workspace's line shows how many of its runs are in progress, pending or running ("No run
in progress", "2 runs in progress"), the runs per day as small bars, named "Runs per day
in the last 14 days", the count of runs, the denied network connections, and when its
last run started; the band's hint, "Runs and denied network connections in the last 14
days", covers the run and denied counts. Each figure shows once: a workspace that never
had a run shows "No run yet" alone, and one whose runs all started before the 14 days
shows "0 runs" and its last run, with no bars.

## Targets

A workspace's targets have an index and a page each, GitHub's organisation repositories
and repository page in the target's words (`ApiaryWeb.TargetLive.Index`, `…Show`; the
reads are `Apiary.Targets`'s, the looks `ApiaryWeb.TargetComponents`'s).

- **The notation.** A target is its path in mono (`<.target_name>`); its system goes
  before it, faint, only where the same path is in another system of the workspace
  (`Apiary.Runs.shared_paths/2`), and always on the target's header and crumb. A run's state
  is a dot and its word (`<.state_mark>`), the dot alone for a run that completed, never a
  pill.
- **The index** (`/:org/:workspace/targets`, width `list`) is narrowed the way every list
  is (Lists, above): views with the workspace's counts (All, Active this week, Never ran),
  one search, one Filter menu (System, Activity, Policy, Pinned) and Sort (Last run, Name,
  Most runs in 14 days, Most denials in 14 days), with the filters in force as tokens under the
  bar. A filter is a qualifier of the search (`forge:` in the software domain, `mode:`,
  `activity:`, `is:pinned`; `ApiaryWeb.TargetLive.Query`): the menu writes it, and one
  the reader types becomes a token on Enter, never half typed. All of it is the URL; a
  value the page does not know is left out. A row is one line on the row spec: the
  reader's ★, the path the title, the last run as a dot and a time (its word unless it
  completed), a 14-day sparkline of runs with their number, the share that ended well of
  those that ended well or badly (lifted to the text colour below 80 %; red is for denials
  only), the denied
  attempts of the same fourteen days in red when there are any, and the policy mode only where the target overrides it. Pages of 50.
  Below 600 px of table the last run is a line under the path. It reads in one query
  bounded by the fourteen days, and re-reads at most once a second as runs land, changing
  the rows it holds in place.
- **A target's page** is `/:org/:workspace/targets/:target_id`, by the target's public id,
  `tg_…`, never its system or its path (`target_path/3`): Overview at the bare address
  and, with `security`, `…/policy` with the policy's paths after it (`/history`,
  `/document`, `/versions/:n`, `/export`, `/rules/new`, `/rules/:id/edit`). An id the
  workspace does not have, and a tab the reader may not read, are not found. The header
  shows the target in its notation (its path, its system before it only where two
  targets share the path) with the reader's pin, one muted line (its runs since it was first
  seen, its last run, and its mode only where it overrides the workspace's) and Open on the
  system when the system is a host name; the breadcrumb ends with the section, a link to the
  index, and the target, then on a version of its policy `Version 3` and on its export
  `Export`, as on the workspace's Policy.
  - **Overview**: two cards, each one list, the few with a link to the many (its last
    runs; the destinations it was denied in 14 days, each with a faint barred circle,
    never red), beside a plain About column (the
    system and path, when it was first seen and by which run, the same path elsewhere,
    its runs a day, its machines and runtimes). A run that lands is counted, never
    inserted, and comes in when asked.
  - Its runs and its Network access are the workspace's lists narrowed to it
    (`/runs?target=tg_…`, `/network?target=tg_…`).
  - **Policy**: the target's view of the policy (`ApiaryWeb.PolicyLive.Target`): its
    mode card (Follow the workspace, by its name, Observe or Enforce, and whose the mode
    is), the rules in force for it on the list pattern with their Source, and
    its history and document as views under the page's tabs. Its old paths, `/policy/targets/:target_id/…`, send on here
    (`ApiaryWeb.TargetMovedController`).

  A tab is a separate mount; a tab another page's module answers is handed the page's
  parameters, events and messages while it is open.
- **Pins** are per person (`target_pins`): the ★ of a row and of the header, and the
  sidebar's Pinned group.

## Machines

A workspace's machines and pools are where its runs run (`ApiaryWeb.NodeLive.Index`,
`…Show`; the reads and changes are `Apiary.Nodes`'s). A **machine** is one computer that stays registered, such
as `build-01`; a **pool** is one or more machines that use the pool's access key, which
run up to its machine limit, or any number without one. A
**gateway**, the third kind, is a machine that runs go through: an address the runs of its
machines and pools may go through, as each chooses
(`Apiary.Gateways`); its key enrols the gateway and registers no run. The kind is chosen when one is made and never changes. Each is
named in a path by its public id, `nd_…` for a machine, `np_…` for a pool and `ng_…` for a
gateway. Machines is an entry of the workspace's sidebar, in Record after
Targets (`#nav-nodes`, for a reader of `node.read`); the list, the page of a machine, pool
or gateway and the New forms pass `nav={:nodes}`, so it is the current entry on all of
them. The old addresses under `/:org/:workspace/nodes` redirect, `301`, to the same
address under `/machines`, with what followed `/nodes` and the query.

- **The state** of a machine, pool or gateway is never Online or Offline (`ApiaryWeb.NodeComponents.node_state/1`).
  A machine is **running** while it has a run alive by the lost-run check's rule
  (`Apiary.Runs.Liveness.alive/2`): running means "not yet lost". A machine shows
  "Running"; a pool says "3 of 10 running", or "3 running" without a limit; one that runs
  nothing says "Last seen" and a time that ticks, or "Never seen" until a machine of it
  reports. Once a pool's machines are pruned, a day after they were last seen, "Last
  seen" is when one of its keys, revoked ones too, was last used; "Never seen" is for one
  with no machine and no key ever used.
- **The list** (`/:org/:workspace/machines`, width `list`) is on the list pattern (Lists,
  above): machines and pools first, then the heading Gateways with the workspace's
  gateways, the organisation's gateways and the Qory Gateway; one line each, its name the title with its public id beside it in `q-side`,
  and the state word Default beside the workspace's default gateway, its kind in words
  only for a pool ("Pool") and a gateway ("Gateway"; a machine, the usual kind, shows
  nothing), its state, and from `md` the Forager version it last reported. Under a pool's line, its
  running machines as indented lines (name, id in `q-side`, "Running since", its run),
  ten at most, then "and 12 more", which leads to the pool's page; a pool's machine shows only
  while it runs, and a machine added alone has no such lines, its line being the machine. The views are
  All, Running and Not running (`?view=running`, `?view=idle`), counted under the search
  and the kind; one search, `?q=`, words of a name or an id ("Find a machine, pool or gateway by its name
  or id"), and the Filter menu's Kind, Machine, Pool and Gateway (`?kind=node`,
  `?kind=pool`, `?kind=gateway`), each a token under the bar; Sort by Name
  or Last seen (`?sort=seen`: running first, never seen last). Owners and admins have
  **New machine**, **New pool** and **New gateway**, side by side and alike, in the
  header; with none of any kind yet, the empty state, "No machines yet", offers the first
  two, and tells a member that an owner or admin adds machines. New pool, in the header
  and the empty state, is only for one who may set a pool's limit too (`node.set_limit`),
  as making a pool needs it; one who may not reads "Add a machine for one computer that
  stays registered." in the empty state, in place of the sentence that offers a pool.
- **New machine and New pool** are pages of the Machines section at separate paths,
  `/machines/new` and `/machines/new-pool`, on the pattern of a form page (Settings, A form is a
  page, above) in the `read` width: the workspace's sidebar, the breadcrumb ending
  `Machines / New machine` (Machines a link back to the list), the page's heading
  (`PageComponents.page_form/1`, no Back link) and one sentence of what the kind is, with
  "You can't change the kind later"; then the form, a name (it takes the focus), and for a
  pool its machine limit (a whole number up to 10,000, or empty for none), and its foot,
  Add machine or Add pool with Cancel back to the list (`page_form_foot/1`). One who may
  not set a pool's limit (`node.set_limit`) and opens `/machines/new-pool`, or whose Add
  pool is refused, is sent to the list with "Ask an owner or admin to add the pool.
  Adding a pool needs the right to set its machine limit.", or, where the edition has a
  sentence on who sets the limit (`c:ApiaryWeb.Edition.who_may_sentence/2`), that
  sentence and then "Adding a pool needs the right to set its machine limit." Once the
  workspace has a gateway, a machine's and a pool's form ask its **Gateway** too, a select
  (`NodeComponents.gateway_field/1`): Default gateway, offered only while a default
  resolves for the workspace, and then the one the form starts on; Direct, which it
  starts on otherwise; and each gateway by name; under it, which gateway the default is.
  **New gateway** (`/machines/new-gateway`) is the same page with a name and a URL, its
  hint saying where the URL points (the machine that runs qory gateway), what a URL may
  be, and that the gateway's Settings change it later (`NodeComponents.url_hint(:new)`;
  the Settings field's hint, `url_hint(:settings)`, leaves that last sentence out), and
  Add gateway. A refused save stays on the page, the
  error under its field, in core's words (a URL's, or a gateway's, such as "has no
  default gateway"); adding one opens its page on Access key with a
  flash, where its machine gets its key.
- **The page of a machine or pool** (`/machines/:node_id`) has a header (its name and public id, then
  one muted line: its kind, its state and who made it when) and its tabs, the operational
  side first and Settings last, set apart at the bar's right end
  (`NodeComponents.node_tabs/1`, on `PageComponents.page_tabs/1`). Overview and Settings
  are patches of the one LiveView; Access key, between them, is a separate LiveView
  (`/machines/:node_id/access-key`, `ApiaryWeb.NodeLive.AccessKey`). **Overview**: a machine
  as Forager reports it (running since when,
  its run and Forager version, or when it was last seen) or a pool's running machines on the
  list pattern with "3 of 10 running", the runs that did not start at the machine limit, the
  pool's line to contact support once machines past the bound of 256 new ones a day went
  unrecorded, the sentence that each machine there is what
  Forager, run with the key, reports itself as, and its recent runs (`runs.node_id`,
  for a reader of the record) with the way to all of them on the runs list (`?node=`),
  each saying so while nothing has reported, then About (kind, id, machine limit, who
  made it), which leads to Settings; and **Settings** (`/machines/:node_id/settings`), its few
  sections listed in the page, never as a second column (Settings, A machine's): General,
  whose pool's limit is disabled, with "You can't change the machine limit." under it,
  for one who changes the machine or pool but may not set its limit (`node.set_limit`), and
  whose danger zone's Delete machine… (Delete pool… for a pool) expands its
  confirmation in place (Settings, The danger zone) at `/machines/:node_id/settings/delete`:
  what is lost, then Delete build-01? with Yes, delete and Cancel, no field to type, Cancel
  taking the focus.
  Deleting a machine or pool takes it out of the list, frees its name and keeps its runs in
  the record. One the workspace does not have, or a deleted one, is not found. A machine's
  and a pool's About has a Gateway row: Direct; Default gateway, then the gateway it is now
  (a link to its page, with its URL); or the gateway it is set to. Its Settings' General
  chooses it, as the forms do, once the workspace has a gateway or the machine or pool
  is not direct.
- **A gateway's page** has the same header, with a Default badge beside the public id of
  the workspace's default, and the same tabs. Its Overview leads with Gateway: its URL
  with Copy, and Default, "This workspace's default gateway." or "Not the default.", with
  Make default (`Apiary.Nodes.make_default_gateway/2`, `node.edit`) for one that is not,
  which moves the mark at once with a flash; then its recent runs and About, without
  running machines or a machine limit. Its Settings' General changes its name and its URL.
  Delete gateway… is confirmed in place as a machine's is, with a gateway's sentence;
  a gateway that machines or pools still point to, or that runs still go through
  (`{:gateway_in_use, …}`), is not deleted: the confirmation folds, and under the line an
  error notice says why (`NodeComponents.in_use_words/2`): "Machines and pools use this
  gateway: build-01, spot-runners. Point them to another gateway or to direct, then delete it.",
  and for runs going through it, where the refusal names any, "Runs are going through
  this gateway: … Delete it once they end.", or both in one notice. It names the first
  five of this workspace, then "and 3 more", which counts those of other workspaces too,
  never named.
- **An organisation's gateways** (`ApiaryWeb.NodeLive.Gateways`, `/:org/gateways`) are
  offered only where an organisation may have more than one workspace
  (`NodeComponents.organisation_gateways?/0`, from `c:Apiary.Edition.limits/0`); with one,
  the Gateways entry of the organisation's sidebar (`#nav-gateways`, after Audit log, for
  a reader of `node.read`) and New gateway in the New menu are not there, and the paths
  are not found. The list, on the list pattern, says under its heading whose machines and
  pools can use them (`c:ApiaryWeb.Edition.gateway_reach_sentence/2`, `:intro`), then a row a gateway:
  its name and public id, its URL from `sm`, Default beside the organisation's default,
  and Connected, Yes or No by whether it holds an active key. Owners and admins have **New
  gateway** (`/gateways/new`), a form page as a workspace's New gateway is, which opens the
  gateway's Access key tab. A gateway's page is a workspace gateway's page under
  `/:org/gateways/:node_id`, with its Access key and Settings tabs, the breadcrumb and the
  sidebar's current entry Gateways (`nav={:gateways}`). Its Overview adds who can use it
  (`:who_can_use`) and who uses it now, "Machines and pools in Acme › Main, Acme › Build use it
  now." or "No machine or pool uses it now." (`NodeComponents.using_words/2`), naming only the workspaces
  the reader reaches, then "and 2 more workspaces"; the organisation's default reads
  `:default_row`. Its deletion is confirmed in place, naming the organisation, and a refusal names
  the machines, pools and runs of the workspaces the reader reaches and counts the rest
  (`NodeComponents.in_use_words/3`).
- **A workspace's Machines and an organisation's gateways.** Machines lists the
  organisation's gateways under the heading Gateways, after the workspace's, each with
  "Set for Acme" (`#node-<id>-level`), linked to its page, and Default beside the gateway the workspace's default resolves to. A
  gateway of another organisation that serves the workspace is no row of it. A machine's or pool's
  Gateway select groups the gateways by level where there is more than one, "This
  workspace" first, then its organisation, then each organisation that serves it,
  named, in the order their defaults resolve (`Apiary.Gateways.levels/1`), and its hint names the organisation
  whose default it is. Where a machine or pool uses a gateway of another organisation, its About,
  its Default row and its Access key tab name it "edge-01 of Acme", with its URL, a link
  to its page under that organisation's Gateways only where the reader reads it there
  (`node.read` at that organisation, `NodeComponents.gateway_path/2`). Who manages the machines is the core's sentence unless
  the edition gives one (`c:ApiaryWeb.Edition.nodes_managed_by_sentence/1`); the
  machine limit's refusal and hint ask `c:ApiaryWeb.Edition.who_may_sentence/2` for
  `node.set_limit`, "You can't change the machine limit." when it gives none.
- **Access key**, a tab of a machine, pool or gateway. A machine or a pool whose choice
  leads to a gateway (`Apiary.Gateways.chosen/1`) reads, at the top of the tab, on the
  command's page, Key for a machine and a key's Forager file, an info notice: "Runs of build-01 go through the
  gateway edge-01, at https://edge.example.com.", and, while the gateway holds no active
  key, "edge-01 has no active access key, so it isn't connected."; one on Default gateway
  while no gateway is the default reads "No gateway is the default now."; a direct one
  reads none (`NodeComponents.through_gateway/1`). The command and the Forager file point
  at Qory Apiary, through that gateway: the command carries `--via` and the gateway's URL,
  and the Forager file a `via` line (`Apiary.AccessKeys.via_lines/1`); a direct machine or pool, a
  gateway, and one on Default gateway while no gateway is the default see neither. A gateway's Access key tab has the same
  layout, worded for a gateway: its key enrols the gateway and registers no run. While it has no active key, owners and admins read
  "How do you want to connect build-01?", "build-01 connects to Qory Apiary with a key.
  Choose one of two ways to give it one." (a pool's: "spot-runners connects to Qory Apiary
  with a key; its machines share one. Choose one of two ways to give it one."), and
  two options of equal weight, side by side from `md`, stacked below it, of one height
  (`items-stretch`), each its icon and title, "Choose it when …" in the body colour, what
  happens in two muted sentences, then the same four facts in the same rows (a `dl` of two
  columns, the labels faint: Key made, Secret, By hand, Needs), a waiting command where
  it is the command's, and one button at the foot (`mt-auto`), so the buttons line up.
  No steps, no code, no variable and no Copy. **Connect with a command**: "Choose it when
  you can open a terminal on build-01: a laptop, or your server.", "You get one
  command to run on build-01. It carries a one-time code, not a key, which works once
  within 15 minutes. qory makes the key on build-01, sends Qory Apiary only its public
  half, and saves everything else there itself.", Key made "On build-01, by qory", Secret
  "Stays on build-01; it is never shown", By hand "Nothing", Needs "A terminal on
  build-01", then Get the command. **Generate a key in the browser**: "Choose it when
  build-01 runs in a CI job, or on a machine you can't open a terminal on.", "This browser
  makes the key, and Qory Apiary receives only its public half. The next page shows the
  secret once, with everything else the machine needs, for you to set where build-01
  runs.", Key made "In this browser", Secret "Shown to you once, for the machine's or the
  CI's secret store", By hand "The key's ID, its secret, Qory Apiary's public key and
  address", Needs "This page open over HTTPS", then Generate a key. A machine lists the
  command first, its button primary; a pool lists Generate a key in the browser first. A
  member reads, under "Connect build-01", "build-01 has no key yet, so it isn't connected
  to Qory Apiary. An owner or admin connects it." A command not yet run shows
  in the command's option, above its button, or its row under Add a key: "A command is waiting to be run
  on build-01.", "D got it at 14:17. It works once, until 14:32. It was
  shown once: if it's lost, cancel it and get a new one." and Cancel the command…,
  confirmed in place ("Cancel the command from 14:17?", Yes, cancel it and Keep it); its
  button becomes Get a new command. There is no list of codes. With keys, the tab lists
  them under Keys, with a count, one card each, headed by its label and Active or Revoked:
  Key ID, `ak_…` with Copy, since the ID can always be seen again, Added ("Connected with
  a command by D, …" or "Generated in a browser by …", D being the person's letter),
  Secret (where the key's secret is), Last used ("Not yet" while unused) and Fingerprint,
  and an active key's **Forager file**, for everyone who reads the machine or pool, and Revoke…,
  confirmed in place. A key whose record doesn't match its integrity code says so on its
  card: "… It can't be used." Under the keys, Add a key says how to move to a new key, add
  it either way and then revoke the old one, and offers the two ways as compact rows, in
  the same order, each its title and its "Choose it when …" line, with its button. At two keys, the most a machine or a pool has, it has no
  buttons, only "build-01 has two keys, the most a machine can have. Revoke the one it no
  longer uses to add another." A member sees the keys and none of the actions. At the foot, once
  it has an active key, **Configure a machine** (`#node-configure`), for everyone,
  at the limit too, at most 46rem wide: "A machine connected with the command needs
  nothing more: qory saved all of this on it. Don't set these again there; qory refuses a
  key ID or a public key set twice." and "With a generated key, set these where the
  machine runs qory.", then four numbered steps (`q-steps`): 1 "Point the machine at Qory Apiary." ("In the Forager
  file. It is required: without it, qory ignores the three variables below.",
  `forager.yaml` with Copy lines; a pool's "Point the pool at Qory Apiary.", a
  gateway's "Point the gateway at Qory Apiary."; behind a gateway "Point the machine at Qory
  Apiary, through edge-01.", the text adding "via sends every request to Qory Apiary through edge-01.",
  and a pool's "A starter that reaches Qory Apiary directly can leave via out.", the
  lines ending `via:` / `url: https://edge.example.com`), 2 "Set Qory Apiary's public
  key." ("QORY_APIARY_PUBLIC_KEY.
  The same for every machine connected to this Qory Apiary.", the value with Copy), 3
  "Set the key's ID." (with one active key, "QORY_ACCESS_KEY_ID." and its ID with Copy;
  with two, "QORY_ACCESS_KEY_ID: the ID of the key the machine uses, on its card
  above."), 4 "Keep the key's secret in a secret
  store." ("QORY_ACCESS_KEY_SECRET. It was shown once, when the key was generated, and is
  never shown here. If it is lost, generate a new key and revoke the old one.", text
  alone, never a value or a Copy).
- **Connect build-01 with a command** (`/machines/:node_id/access-key/new-code`, owners and
  admins; its crumb is Command) is where Get the command leads. The click makes the
  enrolment code at once, with defaults: no label hint, so
  qory names the key after the machine's host name; there is no form. The page shows the
  whole command, `qory access-key enrol https://apiary.example.com` and the code, wrapped,
  with one Copy command. For a machine or pool whose choice leads to a gateway, the command
  carries `--via` and the gateway's URL before the server's address (`qory access-key
  enrol --via https://edge.example.com https://apiary.example.com` and the code), the
  description reads "The command connects build-01 by itself, through the gateway
  edge-01: it makes the machine's key there, saves it, and writes Qory Apiary's address
  and public key and the gateway's address into the Forager file. The secret never leaves
  the machine.", and a line under the command reads "If edge-01's certificate is signed
  by a private certificate authority, add --via-ca-file and that authority's PEM file."
  (`NodeComponents.via_ca_line/1`). An address in the command with a character a shell
  acts on is single-quoted (`NodeComponents.shell_word/1`). For a machine or pool that has or had a key, the command carries
  `--replace` (`qory access-key enrol --replace https://apiary.example.com` and the code,
  `--replace` before `--via` when both),
  shown and copied alike, with the line "It moves build-01 to a new key. The old key keeps
  working until you revoke it on the Access key tab." under it while a key is active, or
  "It moves build-01 to a new key." alone once every key is revoked; a code waiting
  unused does not count. Then "It works once, until 14:32, 15 minutes from when you got
  it. This is the only time it is shown." and "Waiting for build-01 to run it. This page
  shows when it is connected." The code is never shown by itself, and the page never
  names it. When the machine runs the command, the page turns, live, to "build-01 is
  connected. Its key arrived at 14:20 and is active.", with the Key and its Fingerprint,
  and "qory printed a fingerprint on build-01 when it ran the command. If it isn't this
  one, revoke the key on the Access key tab." When the server's address
  (`ApiaryWeb.Endpoint.url/0`, from `PUBLIC_URL`) is a loopback one, such as
  `http://localhost:4100`, a notice says "Machines can't reach this address. … Set
  PUBLIC_URL to the address machines use, and the command will carry it."
- **Generate a key for build-01** (`/machines/:node_id/access-key/generate`, owners and
  admins; at the key limit it goes back to the tab with "build-01 holds two keys already.
  Revoke one before you add another.") is a form page: "This browser makes a key for
  build-01. You see its secret once, to copy into your CI's secret store, or the settings
  of the system that runs it; Qory Apiary receives only the public half. The key's ID stays on
  the Access key tab." (a pool's ends its first part "… or the settings of whatever runs
  the machines"), then one field, Name of the key, filled in with its name (then
  `-2` when a key has that name), its hint "Shown on the Access key tab, so you can tell
  its keys apart.", and Generate key ("Generating") with Cancel.
  The browser makes the Ed25519
  key (the `GenerateKey` hook) and sends Qory Apiary the name and the public key alone;
  the form has no other field. Where the browser can't make one it says why and Generate
  key stays off: "This browser makes keys only on a page served over HTTPS. Open Qory
  Apiary over HTTPS, or connect the machine with a command." or "This browser can't make
  an Ed25519 key. Use a current Chrome, Edge, Firefox or Safari, or connect the machine
  with a command."; a key lost on its way says "The connection to Qory Apiary dropped
  before the key was confirmed, and its secret is gone. If a new key shows on the Access
  key tab, revoke it, then generate another." Anything sent beyond the name and the public
  key, a name holding a secret, or a public key that does not decode as one, goes back to
  the tab with "The key wasn't added. Try again.", and nothing is added.
- **Key for build-01** (`/machines/:node_id/access-key/keys/:key_id/generated`) is what
  Generate key leads to, with no flash: "Do these where build-01 runs. Only the secret
  can't be seen again.", the notice "**The secret is shown once.** …", then four numbered
  steps, each value with Copy. 1 "Store the secret." ("In the secret store of the system
  that runs build-01, such as your CI's.", `QORY_ACCESS_KEY_SECRET`, tagged "secret ·
  shown once"), 2 "Set the key's ID." ("It stays on the Access key tab.",
  `QORY_ACCESS_KEY_ID`), 3 "Set Qory Apiary's public key." ("The same for every machine
  connected to this Qory Apiary. It stays on the Access key tab.",
  `QORY_APIARY_PUBLIC_KEY`, the pin as JSON), 4 "Point the machine at Qory Apiary."
  ("In the Forager file. It is required: without it, qory ignores the three variables.", the
  three lines `gateway:`, `server:` and `url: https://apiary.example.com` with Copy
  lines; behind a gateway as Configure a machine's first step says). The server's address and public key are the instance's, the same for every
  organisation, workspace and machine; the key comes from `APIARY_SIGNING_SECRET`. Then Done
  back to the tab ("Once you leave this page, the secret is not shown again."). The secret
  is the browser's alone: the server renders its place empty, and the page that made the
  key fills it. Opened again, the page has no notice, no Copy for the secret and no line
  beside Done; where the secret was, "Not shown: only the page that made the key held its
  secret, and this one was opened again. If you didn't copy it, revoke build-01 and
  generate another key." The browser decides which (the `GenerateKey` hook): the server
  renders both hidden, alike for every visit, and never the secret; the page shows the
  notice, the secret's Copy and the line beside Done while its slot shows the secret, the
  "Not shown" line while the browser holds nothing for the key, never both. A page joined
  again after a dropped connection keeps the secret and its Copy. It is the page of an
  active key the reader made in a browser while they
  may add keys; another key's address goes to its Forager file, a revoked one's back to the
  tab.
- **Forager file for build-01** (`/machines/:node_id/access-key/keys/:key_id/forager-file`, an
  active key's alone; a revoked one goes back to the tab with "build-01 is revoked.") is a
  page, not a dialog, which an active key's card opens with **Forager file**: "The Forager
  file's lines for this key. Nothing here is secret." (a generated key's: "What build-01 needs,
  besides the secret. Nothing here is secret.") What follows depends on how the key came. A
  key connected with a command: the `forager.yaml` lines the command wrote (the `server`
  section, each line marked: `url` `# Qory Apiary`, `access_key_id` `# this key`,
  `apiary_public_key` `# Qory Apiary's public key`, the pin in YAML's flow form), "Only
  the key ID is this key's. The address and the public key are Qory Apiary's, the same for
  every machine connected to it.", and "The key's secret is on build-01, in
  ~/.config/qory/access-key-secret, where the command saved it. It has never been on a
  screen." A generated key: four numbered steps. 1 "Keep the secret in a secret store."
  ("It was shown once, when the key was generated, and belongs in QORY_ACCESS_KEY_SECRET
  in the secret store of the system that runs qory. If it is lost, generate a new key and
  revoke this one."), 2 "Set the key's ID."
  (`QORY_ACCESS_KEY_ID=…` with Copy variable), 3 "Set Qory Apiary's public key."
  (`QORY_APIARY_PUBLIC_KEY=…` with Copy variable, then "The same for every machine
  connected to this Qory Apiary."), 4 "Point the machine at Qory Apiary." (`gateway:` /
  `server:` / `url:` with Copy lines; behind a gateway "Point the machine at Qory Apiary,
  through edge-01.", "via sends every request to Qory Apiary through edge-01." and a
  pool's sentence above it, the lines ending `via:` / `url:`). A command key's lines
  behind a gateway end with `via:` and its `url`, marked `# the gateway edge-01`. Done
  goes back to the
  tab, the focus on the link.
- **Clear machine** (owners and admins, `node.clear_instance`) is a text action on a
  running machine and an item of each row's ⋯ menu on a pool's; at
  `/machines/:node_id/instances/:instance/clear` (the id of the machine's row in
  `node_instances`), or, for a machine with no row, at
  `/machines/:node_id/runs/:run_id/clear-instance` (an open run's `rn_` id: the page links
  its newest open run, and the address accepts any open run of that machine), never
  the machine id Forager reports, that line, or that row in
  place of its cells, is the confirmation, no dialog (`<.inline_confirm>`): "Clear
  build-01? Clear this machine if it stopped without reporting that it stopped. Another machine can then
  start at once." with Yes, clear and Cancel; a machine that does not run now confirms at
  the top of the running machines. Its open runs are marked lost, which is not final: a heartbeat
  that counts within three intervals of its arrival brings a run back.
- **Live**: the list and the page read again on `{:nodes_touched, workspace_id}`
  (`Apiary.Nodes.topic/1`) and on a `{:run_changed, run}` of a run on a machine or pool, at most
  every 250 ms, and every 15 seconds, since a machine stops running without an event.
- **Where a run ran**: the run page's details show Machine or pool (linked, or "(deleted)")
  and Machine id (its name and id) beside Key, and so does the runs list's preview, each only
  when the run has one; the runs list takes `machine:`, and `node:` as before (a public id,
  or the name of a machine or pool in use), and has a Machine or pool column from 1300 px
  (`q-rl-c5`) where the workspace has machines or pools.
- **Members** read the list and every tab, without New machine, New pool, Clear
  machine or the danger zone; Settings shows its fields disabled under one line that
  says only owners and admins change them, and the deletion's or the clearing's path
  sends them back with why.

## Widths

Every page starts at the same left edge, 32 px from the sidebar, or from the second column
where it stands beside the page (24 px below 1024 px, 16 below 768); nothing is centred in
the space beside it. `width` is one of three:

- `list` (the default): fluid, up to 1680 px, for the lists and the overviews. A list
  page with a rail or a preview pane beside its list takes `work` and caps itself at
  1680 px (`.q-lp`); from 1920 px an open preview is the one thing that takes more.
- `work`: fluid, with no cap, for a work surface such as a run.
- `read`: a 720 px column, for forms and settings; prose inside anything keeps 72ch.

A thing's tab bar (`.q-tabs`) sticks under the top bar and bleeds to the page's gutter
(`--q-gutter`). The frame is set in the content's sizes, never smaller: a sidebar item and
a tab 14 px and regular, the current one medium (and a tab's underline honey, the current
step); a count 12 px in the sans face, a tab's in a filled pill and a tab's denials red
words without one; a pinned target 12.5 px mono; an entry of the second column 14 px, in the column and in
its disclosure alike.
The classes of the shell are in `app.css`'s shell block, and they are
`@layer qory`: a Tailwind display utility on the same element loses to them, so the shell
hides its parts on phones in that block.

## The set-up

The set-up is the pages a person goes through before the console: the set-up link
(`/setup/<code>`), the sign-up, an invitation, Connect Qory Apiary
(`/instance/set-up?step=<adapter id>|mail`) and the workspace set-up: the kind cards, on
the empty organisation overview `/<org>`, and the template cards on New workspace
`/<org>/workspaces/new`, each a link to its template's page
`/<org>/workspaces/new/<key>`, whose Create workspace
creates the workspace, then each step a page of the workspace,
`/<org>/<workspace>/set-up/<step>`. Each step has its URL,
so a reload or a link opens that step. The signed-in pages show the top bar and no
sidebar, but for the kind cards, the template cards and the template's page, which show the organisation's sidebar, and the steps of
a workspace that exists, which show the workspace's sidebar; the pages read signed out use `Layouts.set_up/1`, a header with the product's
mark and the theme menu.

- **The kind cards** (`SetUpComponents.kind_cards/1`) come before the workspace set-up:
  on the organisation's overview (`/<org>`) while it has no workspace, under "What will
  your first workspace do?", and, without the feature `factory`, on New workspace
  (`/<org>/workspaces/new`), under "What will this workspace do?". There is one card per type of workspace, "Software factory"
  the one, each with the type's name, its summary and an arrow, as the type's newest
  version shows them (`Apiary.Processes.type_texts/1`). The whole card is one link to the
  type's page, named after the type. Each card is 20rem wide, or the column's width where
  the column is narrower, and a further card wraps to the next line. A person who may not
  create the first workspace sees "An owner of Acme creates the first workspace." in place
  of the cards. The cards show no indicator: the count starts at the step Name, in the
  sidebar's group Set up.
- **The template cards** (`SetUpComponents.template_cards/1`) are New workspace
  (`/<org>/workspaces/new`) with the feature `factory`, under "What will this workspace
  do?": the same card for each template, in groups under a heading each. "Qory harness"
  has the Software factory card. "Shared harness" has the templates of the harness repository
  the organisation shares, "Assigned harnesses" those of the sources an instance admin
  assigned to it, and "Connected repositories" those of its connected repositories, for a
  person `harness.save` allows (`Apiary.Stacks.Sources.listed/1`). A card of the last two
  groups shows the label of its repository under the summary. A group with no card and
  no line is not shown. The page reads each repository once the page is connected, at most
  4 at a time, and each group shows "Reading harnesses…" until its repositories are read.
  A module that is not a template, modules past the first 20 and a repository that cannot
  be read have a line in their group. Where the person has used their 10 reads of a
  minute, the page keeps the cards it has, shows "The list continues in 12 seconds. Qory
  Apiary reads at most 10 harnesses a minute for one person.", and reads the rest when the
  minute ends. A shared harness that runs hide shows no address: it is "the shared
  harness". Where the organisation has as many workspaces as the edition allows, New
  workspace is headed "New workspace", with no question, and shows the edition's line in
  an information notice in place of the cards, and nothing is read: "This instance
  allows one workspace per organisation, and Acme has it."
- **The template's page** (`WorkspaceTypeLive`, `/<org>/workspaces/new/<key>`), for the
  people New workspace is for; its breadcrumb is the organisation, New workspace, then the
  template's name. The Qory template's key is `qory.software`. With `workflow_model`, the
  stages a new workspace starts with fill the window on the view-only canvas (The stages
  canvas), and a 24rem side panel beside it has the template's name as the page's
  heading, its summary, "How it works" with its description, "Stages" with "The workspace
  starts with the stages shown. After you create it, owners and admins can change them in
  Workspace settings › Workflows.", the harness line "Harness: Qory harness, stack software"
  (with the feature `factory`), and **Create workspace** under the text. Without
  `workflow_model` there is no canvas: "How it works" takes the main area, and the side
  panel has the name, the summary, the harness line and Create workspace. **Create workspace** creates the workspace, named after the
  template ("Software factory", then "Software factory 2"), and opens its step Name.
  Workspace settings › Workflows > Details then shows its harness with its stack and the
  commit its process came from: "Harness: Qory harness, stack software, commit 4960195",
  or "Harness: Qory harness, stack core" for a workspace made with no template. Workspace
  settings › Harness shows the same harness in the rows Source and Stack.
  The page shows nothing of the workspace limit; at the limit, Create workspace shows the
  edition's line as information.
  A template of a harness repository has the key `<prefix>.<module>`, split at the first
  dot. The page reads the repository, shows "Reading harnesses…", then the canvas or "How
  it works" from the template's process, its name, summary and description, and the harness
  line "Harness: acme/harness, stack support" (for a shared harness that runs hide,
  "Harness: shared harness, stack support") where the Qory page has it. Once the read has
  succeeded, **Create workspace** shows. It creates the workspace from the template the
  page read, named after the template, makes no second read, and opens its step Name. At the
  limit it shows the edition's line as information. Where the source is no longer offered,
  New workspace opens with "Nothing was changed. Try again."; a template whose process,
  artifact types or name is refused shows the module, the repository and what to change.
  A read that fails shows its reason and a link to New workspace; a module that gave no
  template opens New workspace. A key of no template
  place, and any key but `qory.software` without the feature `factory`, is a page that
  does not exist.
- **The frame** (`SetUpComponents.frame/1`) has three parts: the steps indicator, the
  form, and an `<aside>` with what the step does, headed "About" and the page's topic,
  such as **About harnesses**, styled as a settings page's column (`.q-context`): the
  muted colour, no box.
  From 1280 px they stand side by side, 220 · 480 · 320 px with 48 px gaps, from the
  page's left edge. From 1024 px the indicator is a bar on top, and
  the form and the aside stand side by side, 480 · 320 px. Below 1024 px the aside goes
  under the form. In reading order the aside comes after the form. Steps done in another
  system, such as an adapter's set-up in a new tab, are a numbered list in the aside,
  headed by where they happen ("In the new tab", "On GitHub"); the form never repeats
  them.
- **The steps indicator** (`SetUpComponents.steps/1`) lists the steps that
  `SetUpComponents.steps_for/3` builds for the person and the instance, after the
  result of `c:Apiary.Edition.set_up_steps/2`: the instance's steps, under Connect Qory
  Apiary, and the steps an edition adds. Above it: "Step 2 of 3" and a progress bar,
  never a count of the steps left. Each step has its mark: a filled check when done, a
  ring in the primary colour and `aria-current="step"` when current, a dash and
  **Skipped** under a step passed over. Each step done or skipped is a link to that step
  where it has a page, before the current step or after it; Your account is not, and on
  the pages read signed out, only Invitation is. An edition's note about a step goes
  under its name. Below 1280 px the indicator is a bar, "Step 2 of 3: Mail", with **All
  steps**, a disclosure that opens the list; Escape closes it. A page with one step
  shows no indicator, and nor does a step of a workspace: its sidebar's group Set up
  lists the workspace's steps.
- **The group Set up** (`Layouts.app/1`) is at the top of the workspace's sidebar, under
  the link up to the organisation, until the test run passes
  (`SetUpComponents.workspace_set_up/1`): "Set up · 3 of 7", then each step of the
  flow, a link to its page, with a filled check when done and the page's step current.
  The rest of the sidebar stays. Steps open in any order.
- **Back** (`SetUpComponents.back/1`) is the first button at the form's foot, left of the
  primary one, and opens the step before the current one; its `aria-label` names that
  step ("Back to Mail"). A step with no page before it, such as the one after Your
  account, has no Back. It is the one Back at a form's foot in the console: a step has
  no Cancel, since there is nowhere to go back to but the step before. A step opened
  again shows what was saved there and can be changed. The step Name has the workspace's
  name in a field, with its address under it as text, which follows the name; once the
  name typed gives another address, a warning says which address stops working; under
  it, "Type: Software factory". **Save and next** renames the workspace. A person who may
  not rename it sees the name, read only, with **Continue**. The type can't change.
- **The chooser** (`IntegrationComponents.chooser/1`), with the `factory` feature, is a
  separate page of the workspace's set-up, the step current in the group Set up:
  `/<org>/<workspace>/set-up/<sources|destinations>/choose?grant=<id>`, opened
  by **Choose** on a card of Work sources or Destinations
  (`IntegrationComponents.grant_card/1`). Its title is “Choose repositories · GitHub ·
  acme”, in the adapter's word for its collections, with the count, such as “3
  selected”, beside it under **Only selected**. Its **Back** returns to the step without
  saving, and **Save**, the primary button, saves and returns to the step. Workspace
  settings › Work sources and › Destinations open the same chooser inside the settings,
  at `/<org>/<workspace>/settings/choose?step=<sources|destinations>&grant=<id>`, with
  the step's section current; there **Back** and **Save** return to the settings page.
- **A workspace in set-up** opens at its overview: with the `factory` feature, until its
  test run passes, every link to the workspace leads to the overview, which shows "Finish
  setting up Main", each step with its state, a line under its name, and a link to its
  page, and **Continue: Model**, to the first step that is not done
  (`SetUpComponents.workspace_set_up/1`). The line is a done step's value where one is at
  hand (Name the workspace's name, Work sources the integrations by name, Destinations
  the repositories by name or, from 3 on, "3 repositories", Model the model as its step
  shows it chosen, Harness "Qory harness" or the harness repository, Machines the
  pool), read for the person as the step's page reads it, "Starts one run to check the
  set-up" for Test run, else the step's page's heading ("Where does work for Main come
  from?"), also for a value the person's step page does not show them
  (`SetUpComponents.step_note/3`). A person who may not take the next step's action, as
  its page checks (`SetUpComponents.changes_step?/2`), reads "Main is being set up", "Owners and admins of
  Acme finish the set-up.", and the steps with their state, with no **Continue**. The
  organisation's overview shows "Set-up: 3 of 7 steps" under the workspace's name.
- **The link up** is the first line of the workspace's sidebar on every page of the
  workspace: the organisation's name, with an arrow up, a link to `/<org>`. The
  breadcrumb keeps its link to the organisation.

## Components

A page composes components; it never writes a custom button, input, table, modal or
badge. The general ones are in `ApiaryWeb.CoreComponents` (`core_components.ex`); the
ones a group of pages shares are beside them: `RunComponents` for the runs list (its
Filter menu's sections, the rail, the pager, the runs table and the preview), the run page
and Network access, `RunPageComponents` for the run page,
`PolicyComponents` and `OverviewComponents` for theirs, `PageComponents` for the patterns
every page is built from inside the frame, `SettingsComponents` for the settings', and
`ApiaryWeb.RichText` for a translated sentence with markup in it. A look a second page
needs becomes a component, or an attribute of one, not a copy.

- **`ApiaryWeb.PageComponents`**: `page_header/1`, a page's title (its one `<h1>`,
  `tabindex="-1"`), one line of what it is for and its actions; `page_tabs/1`, a thing's
  tabs (a target's, a machine's, a run's), links, Settings, where the thing has it, last and
  set apart at the bar's right end, and a settings section's
  (`place="section"`, in the flow, wrapping); `settings_page/1`, a page of a level's
  settings, whose sections the frame lists (Two levels, under The shell); `page_form/1` with
  `page_form_foot/1`, a form as a separate page, its title, one line and the form, with
  no Back link in its header, since Cancel at its foot and the breadcrumb lead back (a
  link at a page's foot that names where it leads stays
  where a page has one); `context_column/1`, a form with an `<aside>` beside it, headed
  "About" and the page's topic, such as **About models**, and labelled by that heading,
  in the muted text with no box (A form is a page,
  under No modals); and
  `not_on_runs/1`, the one plain line a page over data no run receives says, in the
  page's sentence (`inner_block`, required): the component adds no words.
- **`<.button>`** has the variants `primary`, `default`, `ghost`, `danger`,
  `danger-ghost` and `link`, and renders a link styled as a button when given `navigate`,
  `patch` or `href`, unless it is `disabled`: a disabled one is a `<button disabled>`
  whatever its path, never a link that still focuses and patches to itself (the pager's
  Newer on its first page). `primary` marks the one main action of a screen. `loading_text` is
  the gerund ("Saving") the button shows, with a spinner and `aria-busy`, while its form
  submits; the button keeps its width.
- **`<.input>`** is every field but the sign-up page's new password; with `prefix` a text
  input shows, in mono before the value and as one field, what the value completes: the path of the
  organisation before a workspace's slug. A caller's `aria-describedby` is merged with the
  field's descriptions (its hint, its errors), never replaced by it.
- **`<.input type="choice">`** is a select whose options each have a title and a line
  under it (`%{value:, title:, subtitle:}`), where a native select would join the two in
  one line of text. It is a button, styled as a select, that shows the chosen option's
  title and subtitle, or the `prompt` in the faint colour. Options may come in groups,
  `{heading, [option]}`, such as Source's linked repositories, assigned sources and
  public address: each heading shows above its options, an empty group's too, and the
  radios stay one radio group, each described by its heading and its subtitle. An option
  with `disabled: true` shows faint and cannot be chosen, such as Reading… while a list
  loads; the keys pass over it and its radio is never sent. The button opens a panel in
  place, under it and in the flow, never a dialog (No modals, above): a native radio
  group named like the field, so the form sends the value as it sent the select's, and
  `form/3` in a test sets it as it sets a select. The chosen option has a check mark;
  the radios' circles are hidden, and the row shows the focus ring. The `Choice` hook
  (`assets/js/hooks/choice.js`) has the menus' keys (below): a click opens the panel and
  leaves the focus on the button; Enter, Space and ArrowDown open it and focus the
  search box, else the chosen radio, else the first. The arrow keys move among the
  radios and check them, as radios do; Enter or Space, or a click on an option, chooses
  it, closes the panel and returns the focus to the button. Escape closes it and puts
  back the option chosen when it opened; with none chosen then, it keeps the one checked
  since, as a form with no value for the field would send no key for it. Tab and a click
  elsewhere close it and keep the choice. Without a search box a letter goes to the next
  option whose title starts with it. The button's `aria-expanded` and `aria-controls`
  point to the panel, its name is the label and the chosen title and subtitle, and each
  option is described by its subtitle; an error marks the button `aria-invalid` and
  describes it, so a failed submit focuses the button. Above eight options, or with
  `search`, the panel has a search box that narrows the options in the browser by title
  and subtitle, keeps the chosen option and any marked `keep` in view, hides a heading
  none of whose options show, and says the count across every group in a polite status,
  or that nothing matches. The box has no name and the hook stops its input events, so
  it never sends a change. The hook sets the panel's `hidden`, the button's
  `aria-expanded` and the hidden options, which a patch leaves alone
  (`JS.ignore_attributes`), and the box sits in a `phx-update="ignore"` block, so the
  patch that answers an arrow key's change leaves the panel open and narrowed.
- **`<.new_password_fields>`** is a new password and its confirmation, as the sign-up page
  asks for them without mail, and a password link's page. The server never writes a password back: each input is the
  browser's (`phx-update="ignore"`) and drawn without a value. Its errors are drawn under
  the input, outside it, and mark it (`aria-invalid`, `aria-describedby`) as they come and
  go.
- **Forms** are `novalidate`, every one, plain `<form>` and `<.form>` alike: the browser
  neither checks a field nor shows a validation bubble, and the server answers a field that is
  wrong with an error under it (`<.input>`'s, tied to it by `aria-describedby`), in the
  page's words. A field keeps what helps a person, `required`, `type="email"`, `inputmode`,
  `autocomplete`, for assistive technology and a phone's keyboard; so a check the browser
  made is the server's too. A whole number is a text field with `inputmode="numeric"`,
  not `type="number"`, whose value the browser empties when it is not a number.
  `test/apiary_web/novalidate_test.exs` fails for a form without the attribute.
- **`<.command_line>`** is a terminal command for the person to run:
  `claude setup-token` in the help of a Claude subscription's key, the enrol command on
  the set-up's Machines step, and `mix docs` on the page `/docs` shows where the docs are
  not built. It shows the command on a separate line in code font, with an icon button whose
  tooltip and name are Copy command, Copied once it has copied the command, its
  whitespace trimmed. The component adds no prompt sign.
- **`<.external_link>`** is every link out of the console: it opens in a new tab, with
  `rel="noopener noreferrer nofollow"`, an icon that shows it leaves and "(opens in a new
  tab)" for a screen reader. A url is a link only when it is absolute `http` or `https`
  with a host and no user name or password (`external_url?/1`); anything else, or none,
  is the same words as text, so a url from a record is never a `javascript:`, `data:` or
  relative link.
- **`<.inline_confirm>`** is a confirmation in place (No modals, above): the question,
  one muted sentence of what happens, the act's button and Cancel, on one line that
  wraps. The group is named by its question and described by its sentence (`<id>-sub`),
  so a screen reader reads what happens, "This cannot be undone." included. Cancel takes
  the focus as it shows and Escape cancels; both lead back by `cancel`, a patch or a JS
  command. A table shows one in place of the cells of the row
  named by `confirming` (`<.table>`'s `confirm` slot), tinted the error's soft colour
  when its button is red, neutral otherwise: one cell across the row, its content sticky
  and as wide as the table's box (`q-confirm-view`), so that in a table wider than its
  box the question and its buttons stay in view however far it is scrolled sideways, and
  Cancel takes the focus without scrolling the question away (`rule_list/1`'s row is the
  same). A danger zone's line wraps it with what is lost and the field to type
  (`SettingsComponents.deletion_confirm/1`), its button Yes, delete, Deleting while it
  acts, unless the act names other words (`confirm_label` and `busy_label`, which
  `danger_action/1` takes too). There is no modal component.
- **Menus** are daisyUI dropdowns under the `Menu` hook, whose trigger is the button with
  `aria-haspopup`, or, for a disclosure, the one with `aria-controls` and `aria-expanded`
  (the filter chips, Filter, Jump to date): a click opens and leaves focus on
  the trigger; Enter, Space and ArrowDown open and focus the first item, ArrowUp the last;
  the arrows wrap, Home and End go to the ends, Escape closes and returns focus. The items
  are not tab stops (`tabindex="-1"`, as `<.menu_item>` renders them): Tab closes the menu
  and moves on from its trigger. A field inside a Filter section keeps a field's keys, and
  ArrowDown from a section's search goes to its first option. With
  `data-float` the list is a popover in the top layer, placed under its trigger, so no
  scroll region clips it (a row's menu, a list's Filter and Sort). A menu that holds a
  form, such as the runs list's Jump to date, stays open while the page answers it, and
  the page closes it once the form did what it asked: `push_event("menu:close", %{id: id})`.
- **`<.table>`** is a scroll region, focusable and named by its `label`, which
  is required, so a wide table scrolls inside the page and never the page sideways; its
  rows follow the row spec (Lists, above). A column of icons has a header for a screen
  reader (`sr_label`). A settings section is not a named region, so its list
  is the one landmark with the section's name.
- **Tooltips** (`.tooltip` with `data-tip`) take no box while hidden, so a right-hand one
  never widens a phone's page; shown, they wrap at 36ch or the window. Escape hides the
  one under the pointer or focus until the pointer leaves or focus moves (`app.js`).
- **`<.avatar>`** draws a first letter on a circle. In a list of people it sits beside the
  person's address, decorative and hidden from screen readers. In a line of text it stands
  for the person (`email`): the first character of the address, upper case, as an `<abbr>`
  whose tooltip and accessible name are the address, with the address also in visually
  hidden text, so the line reads aloud as "Locked by priya@example.com on 3 Oct.". The
  `<abbr>` is a tab stop, except inside a link or a row that opens (`in_link`), where its
  tooltip opens when the link or the row has keyboard focus. The reader's letter has the
  account menu's colour and its tooltip "dana@example.com (you)"; a line that says "you"
  keeps the word. Two people of one letter look alike, and the tooltip tells them apart.
  A deleted account is the words Former member, with no letter. A tooltip or a label is
  plain text, so it names the person by the whole address.
- **`<.row_menu>`** is a row's ⋯ menu; `<.views>`, `<.list_search>` (with `suggest`, a
  combobox of suggestions), `<.filter_menu>`, `<.sort_menu>` and `<.filter_tokens>` are a
  list's controls; `<.state_word>` says a
  row's state in words; `<.sparkline>` draws runs a day.
- **`<.empty_state>`** says what is missing and offers the one next step. Where it titles
  the page (`heading="h1"`), its title is the page's `<h1>` and takes the focus as a
  header's does (`tabindex="-1"`).
- **Icons** are Heroicons through `<.icon>`, in two styles. Nav and object icons are the
  24 px outline, `hero-<name>`: the sidebar's entries and pins, the top bar, menu items,
  tabs, toolbar buttons (Filter, Sort, Export), find fields, a Filter menu's sections,
  empty states, and an icon that stands for a thing (a target, a run, an access key, a
  workspace). They are drawn at 18 px in the sidebar, 14 px in a Filter menu's sections
  and 16 px elsewhere. Small glyphs are the solid micro, `hero-<name>-micro`, at 12 to 16
  px: check, x, chevrons, arrows, the deny mark, lock, warning, plus, and a row's mark, a
  badge's or a timeline node's. The current navigation item changes its background, weight
  and ring and its icon takes `accent`; the icon never turns solid. A name is written out
  whole in the source, so Tailwind generates its class.

The styles are in `assets/css/app.css`. Overrides of daisyUI are in `@layer utilities`,
wrapped in `:where()` so a Tailwind utility on the element still wins; the classes a group
of pages owns are in `@layer qory` and start with `q-`, clear of daisyUI's names.

An edition adds to a core page only in the places the page gives it: a slot
(`ApiaryWeb.Extension`), a section of the organisation's settings (`ApiaryWeb.SettingsComponents`)
or of the Instance, or an entry of the navigation, of New or of the account menu
(`ApiaryWeb.Edition`). What it renders there links to the edition's pages, which handle its
events; a page whose behaviour differs is the edition's page at the same path.

A component does not ask `Apiary.Features` what the instance serves or the reader is
shown: the page asks with its scope and passes the answer, as the connection row's `security` attribute does. What
Forager reported is untrusted: a component interpolates it and never passes it to `raw/1`.

Untrusted Markdown that a page shows formatted is the one named exception:
`SourceComponents.body/1` passes it to `raw/1` as HTML that is sanitised last, on the
server, with an allowlist of tags, attributes and URL schemes, after every other change.
Links are `https` only, and any other link is its words. An image is never shown: it
becomes a link to it, and raw HTML is not rendered. Task boxes and tables get words for a
screen reader. Show as written shows the text as written, with invisible characters
dropped and control characters shown as U+FFFD, except tabs and line breaks, which it
keeps, interpolated, and plain text is only ever interpolated.

### Storybook

In development the components have a storybook, at `/dev/storybook` of the dev server
(<http://localhost:4100/dev/storybook> under `mix phx.server`): `phoenix_storybook`, a
dependency in dev and test only, whose backend is `ApiaryWeb.Storybook`
(`storybook/storybook.ex`). The core's router mounts it where `:dev_routes` is set and the
library is there (`ApiaryWeb.Routes.storybook_routes/0`); a release, and an edition's
router, have none of it.

A story is drawn with the app's components and stylesheet:
`assets/css/storybook.css` imports `app.css` and adds `storybook/` as a source, so a class
only a story uses (an icon the app does not draw, a layout utility) is generated there and
never in the app's stylesheet. The `storybook` Tailwind profile builds it, and the dev
server watches it (`config/dev.exs`). The header's theme menu draws the stories in `qory`
or `qory-dark`, set as `data-theme` on each story's container. The storybook loads none of
`app.js`, so a hook (`Menu`, `CopyToClipboard`) does not run there: a menu draws its
trigger but does not open.

To add a story, write `storybook/<folder>/<name>.story.exs`, a module
`ApiaryWeb.Storybook.<Folder>.<Name>`:

- `use PhoenixStorybook.Story, :component`, with `function/0` (the component, such as
  `&ApiaryWeb.PolicyComponents.rule_mark/1`) and `variations/0`, `%Variation{}`s and
  `%VariationGroup{}`s; `template/0` wraps each in the markup it needs, a table's row
  in a table;
- or `use PhoenixStorybook.Story, :page` with `use Phoenix.Component` and `render/1`, for
  a composition such as Foundations / Icons.

It renders the real component with neutral sample data, `ApiaryWeb.Storybook.Sample`
(`acme/shop`, hosts under `example.com`), and an attribute a page computes is computed as
the page computes it (`RuleList.list/3`, `Common.list_path/2`). A story's words are plain
English, not Gettext: stories are compiled outside the extraction and ship in no release.
In test every story is compiled with the backend, and `test/apiary_web/storybook_test.exs`
renders every variation and every page in both themes, so a story that a change to a
component breaks fails the suite. The dev server compiles a story when it is opened, and
reloads the page when one changes.

## Colour and themes

`app.css` defines two daisyUI themes, `qory` (light, the default) and `qory-dark`. The
script in `root.html.heex` sets `data-theme` from the theme menu (Auto, Light or Dark,
kept in `localStorage`); Auto follows the system, and without JavaScript the
`prefers-color-scheme` block does the same. The dark theme is designed separately, not
inverted.

- **Colours are tokens.** Beside daisyUI's theme colours, the `--q-*` custom properties
  are exposed to Tailwind as `line`, `line-strong` and `line-field` for borders, `muted`
  and `faint` for secondary and tertiary text, `ring`, `code`, `overlay`, the soft fills
  (`primary-soft`, `success-soft`, `error-soft`, `info-soft`, each with `-content`), the
  lanes, the terminal and the chart series; and as the shadows `xs`, `pop` and `modal`.
  A template names a token, never a literal colour. A new token is defined
  in all three places: `[data-theme="qory"]`, `[data-theme="qory-dark"]`, and the
  `prefers-color-scheme: dark` block for a page without the script. With tokens a
  `dark:` variant is rarely needed. Faint text reaches 4.5:1 on the page and the
  sidebar, not on a fill: the current view's pill, a rail's current target, the current
  version and a row marked by `?rule=` redefine `--q-faint` as `--q-muted`, so every faint
  word on them is drawn muted.
- **Honey is for one thing.** `primary` marks the main action of a screen, a checked box,
  the current step and the mark. It is too light to be text on the light theme: links and
  the active navigation icon use `accent`. A radio's and a checkbox's outline is the
  field's border colour (`--q-border-field`, 3:1 on the page, where `primary` is 2:1);
  `primary` is their checked fill, the outline then a darker `primary`.
- **Colour marks a state, never a mood,** and is never the only carrier: a badge has its
  word, an error its icon and sentence, a connection in the timeline its glyph and word,
  a destination's denied number the words of its split.
- **Borders on the page, shadows in the air.** What rests on the page has a 1 px border
  and at most `shadow-xs`; only what floats (menus, toasts, tooltips, the palette, the
  drawer) has a real shadow.

## First paint and live pages

**The first paint is never blocked.** A mount reads only what the shell and the top of
the page need; every other region is read with `assign_async`, `start_async` or
`stream_async` and shows a skeleton until it lands. These are the ones of
`ApiaryWeb.Async`, which `use ApiaryWeb, :live_view` imports in place of LiveView's, so
the read logs under the page's organisation and workspace. A later read keeps what is on
screen until the new data arrives, and a read that fails says so in a sentence.

**Rows are patched in place, and nothing moves under the reader.** A live page follows
its context's topic and applies what arrives at most every 250 ms. Every row has a
stable DOM id taken from the record (`run-#{id}`), never an index, so a change to a row
on the page updates that row and nothing else. A row that did not exist when the reader
arrived is never inserted above what they are reading: the page says it in words instead
("1 new run", or the new-items pill, `<.new_items>`), and the reader asks for it. The run
timeline is a stream: the `LiveEnd` hook tells the LiveView whether the reader is within
240 px of the end; there new items append, anywhere else the pill counts them, and the DOM
never holds more than 600 items.

**Times tick in the browser.** A relative time, a clock or a running duration is a
`<time>` with the instant in `datetime` (ISO 8601, UTC), a `data-tick` kind (`relative`,
`clock`, `duration`, `seconds`) and the server's now in `data-now`; `<.relative_time>`
and `<.duration>` render them. The `Ticker` hook re-renders every one from a single
interval, once a second, paused while the tab is hidden, and counts on the server's clock
rather than the browser's. It writes in the words and locale the server put on `<body>`,
and in the time zone the element names (`data-time-zone`, the one the server rendered it
in), else the body's, so the server never re-renders for a clock. The full time with its zone is the
`title`. Everything else a person reads as a date, time or number goes through
`ApiaryWeb.Format`.

**Scripts.** A hook lives under `assets/js/hooks/` and is registered in `hooks.js`, the
collection `app.js` and an edition's bundle import. It holds no words (see
[lingo.md](lingo.md)), and keeps in `localStorage` only a reading preference, such as
the theme, the sidebar's fold or the keyboard shortcuts; filters, the order, the page and
a chosen row are query parameters.

**The content security policy.** Every page, the storybook's and the development tools'
included, carries a strict `Content-Security-Policy` (`ApiaryWeb.ContentSecurityPolicy`):
`script-src 'self'` and the request's nonce, so only the console's bundles and the
scripts that carry the nonce run, and a script a bug lets into a page does not. A page
keeps to it:

- A `<script>` written into a template carries the nonce, `nonce={@csp_nonce}`, as the root
  layout's theme script does. Anything else a page runs is a hook in the bundle.
- No `on…=` attribute (`onclick`, `onload`, …) and no `javascript:` address. A
  `phx-*` binding and a `Phoenix.LiveView.JS` command are not inline script and need
  nothing.
- Scripts, stylesheets, images, fonts and form targets are the console's origin (an
  image may also be a `data:` address), and no page is framed, except the development
  tools' pages under `/dev`. Inline styles are allowed (`style-src 'self'
  'unsafe-inline'`): `<style>` elements and `style` attributes, which the run page's
  terminal writes as it runs.

`ApiaryWeb.ContentSecurityPolicyTest` (`test/apiary_web/content_security_policy_test.exs`)
requests every GET route, signed in and out, and checks each page's markup, its dead
render and a LiveView's connected one, without a browser: it fails on the header missing
or changed, and on anything in the markup the policy would refuse. What runs in a browser
(a script or a style a bundle creates) it does not see. A route with a parameter it does
not fill fails until it is filled there.

## The run page

A run is a work surface (`ApiaryWeb.RunLive.Show`, width `work`): the column takes the
width, and from 1280 px the **Details rail** (280 px, sticky under the top bar, scrolling
separately) sits beside it on every tab, Terminal too; below 1280 px Details is a button
under the header. The Timeline tab's content, the Run list included, stops at 72rem,
left aligned, so a row's time stays near it; the Details rail, the header and the tabs stay
where they are, and Network access and Terminal keep the column's whole width. The terminal
takes the whole window through Focus (The terminal, below). The top bar's breadcrumb ends with Runs, a link to the list,
and `Run 14`, a link to the Timeline on the other tabs; the run's target is on its meta line, not in the breadcrumb, and the
page draws no other breadcrumb.

A run's address, `/:org/:workspace/runs/:run_id`, has the run's number, one count
for each workspace, from 1 (`Apiary.Runs.Run`, `number`). A work item that moves into a
workspace whose count is lower raises that count to the work item's highest number, so the
workspace's numbers jump. An address with the run's `rn_` id,
the id the API gives, is sent on to the number's address when the run is in the
workspace; a number or `rn_` id of no run of the workspace, the run id on the machine and
any other value are not found, the same page for each. The header, the breadcrumb, the
lists and the titles show a run as "Run 14"; Details' Record shows "Run id", the run's `rn_`
id, with Copy, because support and diagnostics find a run by it on the whole server
(`GET /v1/runs`, signed with a diagnostics key, lists the instance's runs with this id);
the run id on the machine on the next row, "Run id on the machine", and the search finds
a run by its `rn_` id or the run id on the machine. Other than on Details and in a line
that sends the reader to support, the run page, the lists and the titles show no `rn_`
id. Details and the runs list's preview show the instance id
Forager claimed for the run, when it claimed one, under "Machine id".

- **The header** is "Run" and the run's number, `Run 14`, alone; then the title the run
  gave in its `about`, when it gave one, on the next line; then, when the run names a kind or
  subjects, one line of what it is about: the kind, then at most three subjects, each its type and ref
  as given and a link out (`<.external_link>`) with its title as the tooltip, then "+N
  more" (all of them are in the rail's About); then one muted meta line that starts with
  the state as a dot and its word (`ApiaryWeb.TargetComponents.state_mark/1`), then, each
  after a faint middle dot, why it ended in words (Cancelled · time limit reached,
  Completed · all checks passed), the runtime's exit for a session's run that failed with
  no words ("exit 1", "SIGKILL"), how alive the run is while it runs, the target (its
  page), the runtime, the host, when it
  started, how long it took (left out for a run that did not start, which never ran) and
  its denials, in red, which lead to its denied connections. At the right: the ⋯ menu
  (Copy run id, Raw log, Download log, a file with the `rn_` id as its name,
  `rn_0123456789abcdef.log`), and no Close: Qory Apiary records what a run reports and
  never ends a run it did not start; it starts none today. The seven
  cells of v1 are the rail's. A run that ended badly (Failed or Lost) shows how under the
  meta line, after "How it ended". A paused run shows its paused line there, whole, with
  no "Jump to it" (`ApiaryWeb.PauseWords`): "Paused: every key of Northwind Claude is in
  cooldown until Fri 14:00. It continues in run 15.", the run's number a link to its
  page, while every key of its provider was in cooldown as it ended and that time is
  still to come, the time as a key's row on Model providers shows it; else "Paused: a
  key of Northwind Claude reached its limit. It continues in run 15."; "Paused: a key of
  Northwind Claude reached its limit." where no run continues it; and, once the provider
  is deleted, "Paused: a model key reached its limit. It continues in run 15.", or
  "Paused: a model key reached its limit." where no run continues it. A provider that the
  instance admin set up, outside the run's organisation, is not named: "Paused: every
  model key is in cooldown until Fri 14:00. It continues in run 15." while that time is
  still to come, else the lines of a deleted provider. On the work item's page, the
  run's row on Explore and the stage's round show the same line in place of the run's
  state, the number a link where the reader may read the workspace of the run that
  continues it. For a run that a failed step of its preparation stopped, the line states
  what happened at that step, with no advice, such as "Start the
  wall failed with exit code 125.", on every pool. Else the line is the last result of its
  timeline that was no success, else its
  last failed turn or tool, in one cut line whole on hover, with "Jump to it", the
  timeline at that item. A run with a failed push or copy step looks only at the newest
  of its results and failed turns, and shows that item if it is a failure. Else a run
  whose push failed shows what happened at the push, with no advice, such as "Push work
  to git.example.com/acme/web-shop failed with exit code 1." A prebuild whose image was
  not saved shows the first sentence of the cause line of Save the outputs, in plain
  text, before its timeline's results. A prebuild that completed shows that line too: it
  is the one Completed run with "How it ended". A prebuild lost or cancelled before its
  image arrived shows that line only when the header has no other line on how the run
  ended: no starter's outcome in place of the state, no end reason beside it, such as
  "stopped responding", and, for a lost run, no line from a failed step, item or push. A
  step's line wraps whole and has no "Jump to it".
- **The tabs**, Timeline, Terminal and Network access, stick under the top bar; each is a
  live action of the one LiveView, so a tab is a patch. Terminal is the log's
  (`run.read_log`): for a reader who may not read it, as where an edition hides the run's
  Terminal, there is no tab, no Raw log or Download log, no Terminal on Details, and the
  notes on session events leave the terminal out. An old link to a run's Details tab
  (`/runs/:run_id/details`) lands on the Timeline with Details open, and the address
  becomes the Timeline's.
- **Details is one element** (`#run-details`), after the header and before the tabs at
  every width, so the two places never disagree and no id is drawn twice; its reading and
  keyboard order is the header, Details, the tabs, then the tab's content. From 1280 px it
  is the right column, level with the header, beside every tab. Below 1280 px it is a
  **Details button** under the header (`#run-details-toggle`, a disclosure with
  `aria-expanded` and `aria-controls`, as the settings' section button): closed when the
  page opens, it opens the same element in place above the tabs, its sections as cards,
  pushing the tabs down; not sticky, not a modal. It stays as the reader left it across
  the tabs; Escape on it closes it and keeps the focus on it. The Record's Session is read
  again when the session starts, whatever the tab.
- **The Details rail** is key and value lines under small headings (About, Run, Labels,
  Command, Record, Policy in force), no chip, and no card in the right column; the run's labels are its
  identifiers, in mono, and the target's label links to the target's page. Run has Peak
  memory and CPU time after Duration, each only once a session reported it: the peak,
  "9.8 GiB", or "9.8 of 16 GiB" with the memory of the run's machine type, both in GiB to
  a tenth; the CPU time as a duration, "12 s", "41 m 10 s", "5 h 00 m". When sessions of
  one run overlap, Peak memory shows the highest single peak. Both cover everything behind
  the session's wall. Run has Host, Workflow (where the run has one), Wall, Key, Machine
  type, then Image. Machine type is the type the claim answer had, by the name of the
  type that has its key, then the key in mono, the key alone where no type has it,
  absent for an answer without one; for a queued run, the type it is queued on. Image is
  shown for a run behind a wall: the image Qory Apiary gave the run, with "Prebuilt for
  this target" under it where the image is at the place a build for the run's target
  pushes its image, and with no line under it elsewhere, as a machine type's image was;
  else the image the run reported, with "The pool's default image." under it when the
  run started in its pool's default image. A queued run shows no Image row. Where the
  reader is not shown the factory feature, Image is the image the run reported, with no
  line under it. Run's Policy row and the Policy in force section show only for a run
  whose policy event arrived.
- **About** is the rail's first section, shown when the run names a kind, a subject or
  details: Kind; Subjects, each its type and ref, a link out when its url may be one, with
  its title muted under it, cut to a line and whole on hover; then the details in mono, by
  key, a row per member, a member that is a non-empty object a row per member of that object,
  keyed `outer.inner`, a string as given and anything else as compact JSON, each value
  wrapped and never cut. The title is the page's `<h1>` and is not repeated there.
- **A subject's words** (its type, ref and title) are each isolated in a `<bdi>` wherever
  they show, in the runs list, the header and the rail, so a bidirectional character in
  one reorders nothing around it; a subject's link has as its tooltip its title and the
  host its url parses to ("Login redirects to a blank page · tracker.example.com"), or
  the host alone.
- **A run's title and kind** are each isolated in a `<bdi>` wherever they show as markup
  (the run page's `<h1>` and About, the runs list's row and preview, a target's runs, the
  Overview's rows, Network access's hits and ⌘K's results), in a
  sentence too (`{:bdi, title}` of `ApiaryWeb.RichText`); a tooltip, the page's `<title>`,
  an `aria-label` and an announcement hold them as plain text.
- **The Timeline is an overview of the run** (`Apiary.Runs.Record.Overview`). It lists
  the run's and the sessions' events, one row per agent, the agents' texts, the artifact
  versions the run pushed, failures and denials, and each tool call that was the only
  open call at a connection. A routine tool call, one that finished or still runs with
  no connection and no denied connection inside, is in the Terminal only. A call that
  failed or was denied, that has a connection or a denied connection inside, or that has
  no end after its session or the run ended, is listed. A call to the subagent tool
  (`Task` or `Agent`) follows the same rule, as its subagent has a row. Thinking has no
  row.
- **The Timeline's rows are one line each.** A tool row is the tool and the first line
  of its `summary`, the part of its input Forager selects, never words Qory Apiary makes
  from a tool's name; a denied tool reads "Not run: denied"; a call with connections
  inside reads "only open call at a connection" under it. A text of the session is a
  **Text** row: its first line, without Markdown marks (a heading's `#`, a quote's `>`, a
  bullet or number, emphasis, code and a link's address). In each agent session, a **Main
  session** row follows the main agent's first prompt, with the prompt's event number: how
  many tool calls the main agent made in that session, routine ones included, and the
  first line of its last text. Its Took is the sum of the durations of the main agent's
  results in that session, and is empty while the run is live and the session has no
  result. The first Main session row has the id `main-session`, a later one
  `main-session-2` and so on. Each subagent is one row, its start, which opens to the
  subagent's rows. A **Pushed** row is a version the run pushed
  (`Pushed proposal/main version 2`: the artifact's type and name, and the version's
  number), placed by the time it was pushed among the rows, before the first or after Run
  ended too, with no event number; a version pushed while the page is open shows with no
  reload. **Turn finished** and **Result** show no text: the Text row before them has it;
  Result keeps its outcome, turns and cost (`success · 6 turns · $0.09`).
- **Terminal ›** ends each row that has a line in the Terminal tab's Transcript, for a
  reader who may read the log: a prompt, a text, a tool call, a result, a subagent's
  start, and Turn finished in a run recorded before Forager sent texts. A Main session
  row links to its last text. A `?seq=` of a routine call's event goes to that call's line
  in the Terminal for a reader who may read the log, and to the nearest row before it
  for any other reader. A `?seq=` of any other event with no row, such as thinking or an
  allowed connection while Connections inline is off, shows the first row after it, or
  the last row when none follows.
- **The Timeline tab's count** is how many rows the Timeline lists with every subagent
  open, Main session and Pushed rows included, and the same on every tab. An allowed
  connection outside a call counts only while Connections inline is on. The Run list's
  rows do not count.
- **For a reader who may not read the log** the Timeline lists the same rows, with the
  same count, by their labels: no Terminal ›, and no text of the session, such as a
  prompt, a text, a call's summary, input or output, a subagent's message, the Main
  session's last text or a notification's message.
- **Connections inline.** The switch above the Timeline (`?cx=1`) lists the allowed
  connections outside a call as rows, and shows those inside a call under it; it is off
  when the page opens. A denied connection shows whether the switch is on or off, next to
  its tool call when it was the only open call, so a denial is always beside its cause.
  Network access shows every connection.
- **The timeline's open items are flat**: a rule in the item's state's colour under the
  chevron, the content indented beside it, code with a faint label and no border, a
  connection line with a plain glyph and no row tint, the prompt as quoted text with a
  rule.
- **The time columns.** From 1280 px the Timeline has two fixed, right-aligned columns in
  tabular numbers, so the Run list's rows, the run's rows and the connection rows line
  up: a Run list row's start time and duration, and a run row's offset, how long it took
  and its number. Every duration of a run row is in Took, never beside its label. A small
  faint legend labels them, at the right above the Run list's rows ("Started", "Took") and
  above the run's ("Since run start", "Took", "Event"). A faint band
  covers the row under the pointer, so the eye can follow it to the time. Below 1280 px a
  row sets out its times without columns or a legend.
- **The Run list** is the Timeline's first section (`ApiaryWeb.PreparationComponents`,
  from `Apiary.Runs.Preparation`), and the Timeline's whole content while a pending run
  has no event. It is there for a run a node pool claimed, a run with a step that has a
  row, a push, or an artifact version it pushed, and for a run on a permanent machine once
  it ended; any other run has its timeline alone. The list is not drawn when it has no
  row. The whole list shows even when the loaded events start later in the run, such as
  for a `?seq=` link to a late event. Every reader sees the same list, on every pool: the
  workspace's pool, the Qory Pool and another organisation's pool.

  The heading is "Run on" and the pool's name, then the run's state in the word of the
  run's badge: "Run on Qory Pool · Completed", or Pending, Running, Failed, Cancelled,
  Paused or Lost. A run no pool claimed is headed "Run", with its state: "Run ·
  Completed", or "Run · Queued" for a queued run.

  A queued run's list is Queue the run, running with its time counting from when the run
  was queued, then Request a machine, Start the machine, Prepare the machine, Agent
  session 1 and Remove the machine as grey rings with no time. A muted line under Queue
  the run shows why the run waits, the first reason that applies (`Apiary.Runs.Waiting`),
  and is read again when the queue changes, a slot frees, a build ends or a machine's key
  changes:
  1. "Waiting until Qory Apiary reads the harness." while its harness walk is not done.
  2. "Waiting: no pool can take the run" while no pool that serves the workspace is ready.
  3. "Waiting for a machine: no pool offers a machine that fits UI tests, large
     (`ui-tests-large`: 8 vCPUs, 32 GiB, 100 GiB disk)." while no such pool takes its
     type, in the text's colour inside Queue the run's fold, under its events, then, for
     an instance admin, "An instance admin makes the type fit an offer in Instance
     settings › Machine types, or the admin of build-pool adds an offer that fits." with
     the first such pool, "Qory Pool" for the instance's pool. Anyone else reads, in
     plain text, "Contact support with run rn_…, or ask the admin of build-pool to add
     an offer that fits." where the first such pool is a pool of the workspace or of
     another organisation, and "Contact support with run rn_…." where it is the
     instance's pool, whose admins are the instance admins. The header has the cause
     too, after "Why it waits". "Waiting: no pool can start machine type large", under
     the fold, where the run has no spec.
  4. "Waiting for a model key: every key of Northwind Claude is in cooldown until
     14:00." while every key of each of the run's model providers, its model choice's
     provider and its fallbacks, is in cooldown: the run's queueing stores those
     providers (`dispatch_runs.model_provider_ids`), each claim that leaves the run
     waiting stores again the providers it checked, a change of a model choice or of a
     model provider stores them again from the choice in effect, and the line reads them
     (`Apiary.ModelKeys.first_to_leave/2`): the provider whose key leaves its cooldown
     first, and when, the time as a key's row on Model providers shows it. For a
     provider that the instance admin set up, outside the run's organisation, the line
     has no name: "Waiting for a model key: every model key is in cooldown until 14:00."
     Nothing runs when the cooldown ends: the first claim after that time takes the run.
  5. "Waiting for the environment image: a build of northwind/storefront is queued." (or
     "is running."), or "Waiting for the environment image of northwind/storefront." with
     no build live, while it is held for its target's build.
  6. "Waiting for a machine: build-pool runs 3 of its 3 machines." while every pool runs
     as many machines as its limit allows; "Waiting for a machine: Qory Pool runs all of
     its machines." on the Qory Pool, whose count covers other organisations' runs.
  7. "Waiting for a machine: 2 runs were queued before this one."
  8. "Waiting for build-pool to run it." otherwise.

  The page of a queued run has no duration in its header. Details has a Workflow row,
  for a queued run alone, Arguments and Run id on the machine read n/a, and the empty
  Timeline shows "Waiting for the run to start" and "Listening for the run's first
  event." with no sentence that Forager pinged. Run id on the machine stays n/a for a run
  that ended while it waited. At the claim the page becomes the page of
  the run the pool registered, without a reload. A run that ends while it waits keeps
  its number: Cancelled when its work item was closed or undone, or a prebuild was
  superseded or its pool deleted; Failed with its cause otherwise.

  The list has one row per step of the run, each named as an action, in the order the
  steps ran, as in GitHub Actions. A step that is made of steps opens to them, and a step
  with events opens to them, each with its time: Queued, Machine requested, Machine
  started, Started, Finished, Outputs saved and Machine removed. Each top-level row has its
  state, its start time under Started and its duration under Took; the rows inside a step
  have no times, and no duration sits beside a name.
  1. **Queue the run**, for a run a pool claimed: from the queueing this claim came from to
     the claim. That is the queue (`dispatch_runs.queued_at`), or, for a run of the queue
     lapsed or released and claimed again, the moment the dispatch that put it back in
     the queue lapsed (`dispatches.stale_at`) or ended (`dispatches.ended_at`). It opens to
     Queued and its time.
  2. **Request a machine**: from the claim to the starter's `dispatched`, empty without
     one. It opens to Machine requested and its time, the pool, and the machine type with
     its spec, "Large `large` (4 vCPUs, 16 GiB, 60 GiB disk)", or "pool default" while
     the claim answer has none.
  3. **Start the machine**: from `dispatched` to the redemption of the run's code. It opens
     to Machine started and its time, once the machine started. A step of kind `machine`
     (the parts of the machine's start that `qory run` sends, such as `start Docker  3.2
     s`) is no row: its lines are Start the machine's, after a first line, `create machine
     14.8 s`, at the time of `dispatched`, with the seconds from `dispatched` to that step's
     start, written only when the step started no later than the redemption. Start the
     machine is failed once that step failed. It also has, for an instance admin, the
     machine type the pool started, "Started as (instance admins)" and the type its starter
     reported, absent while it reported none, then the machine log, numbered with no
     times; anyone else sees neither. With no machine log recorded, an instance admin reads
     "No machine log has arrived." until a day has passed since the claim (the least the
     machine logs' retention can be set to, under which a prune can have deleted the log),
     and then "Machine logs are kept for 30 days. This machine has none.", with the
     retention's days in force.
  4. **Prepare the machine**: the run's steps that started before the first agent
     session, in order, for a run a pool claimed or not, except the joins and walls, which
     are in the Prepare the session of their Agent session. It runs from its first step's
     start to the end of its last step; on a live run it is running until a step of an
     agent session, or a prebuild's Build the image, begins or the preparation stops, and
     between two steps it has the word Running and no clock. A step of kind `fetch` is
     Clone the repository, `compose` Compose the harness, `image` Pull the images, `build`
     Build the image, `setup` Set up the dev container, `join` Start the agent, `wall`
     Start the wall and `machine` Start the machine; a step of any other kind has qory's
     name, its first letter in upper case, or "Step" and its number when only its exit is
     recorded.
  5. **Agent session 1**, **Agent session 2** and on, one for each agent session. An agent
     session is every session except a bare one and one whose wall failed. A bare session
     is a helper session that `qory run` starts with no runtime, whose
     `dev.qory.session.started` has `bare: true`. A session whose wall failed never ran
     its agent; its steps stay in the Agent session of its join. Each opens to the same
     three steps:
     - **Prepare the session**: the session's join, Start the agent, and its wall, Start
       the wall, with any other step that ran after the start of the session before, in
       the order they ran. A join, and any other step but a wall that runs after the first
       session's start, belongs to the first agent session that starts after it, or, when
       none does, to an Agent session that has not started. A wall belongs to the session
       of the last join before it when no agent session started between the two, as for a
       wall that fails before its session starts; else to the last session that started
       before it. A step with only its exit recorded belongs to the last session that
       started before its exit. It is running on a live run until its session starts.
     - **Run the agent**: from the session's `dev.qory.session.started` to its last
       `dev.qory.session.exited`, with the exit's state: Paused, with the ring of a paused
       run, for an exit `paused`, or `cancelled` with the reason `model_key_limit` from a
       gateway of the earlier contract. The session's Agent session is Paused too, unless
       one of its steps failed, runs or was cancelled. On a run that ended Completed after
       it pushed its questions or a proposal, such an exit is Succeeded, with the check of
       a session that succeeded. It opens to Started; Finished,
       the time of the session's last `dev.qory.runtime.result`, or of its exit for a
       session with no result; Result, "exit 0 · success · 14 turns · 3 m 49 s · $0.84"
       (an exit code of -1 is no exit status and is left out); and Model, from the
       session's last `dev.qory.runtime.started`. A session whose runtime, the `runtime`
       of its `dev.qory.session.started`, is not Claude Code (`claude`) then has a note:
       "Only Claude Code sends session events. This session ran qory: its output is
       under Terminal, and its connections under Network access." For a reader without
       the Terminal, the note ends "its connections are under Network access." A Claude
       Code session whose hooks sent no event has the note about the wall instead, "This
       run's session events could not be recorded: the wall it ran behind runs inside a
       virtual machine.", or, on a run with no wall, "No session events arrived." Each
       Claude Code session of the run has that note, as the wall and the hook events are
       counted for the run. In a run of two sessions on different runtimes, each session
       has the note about its runtime. No note is above the Run list. A run whose Timeline
       follows the list, as one whose sessions ran no agent, has the notes after the
       list, above the Timeline, and a run with no Run list has them above its Timeline.
       Then comes that session's Timeline,
       with that session's Main session row: `timeline` for the first agent session,
       `timeline-2` for the second, and so on. An event whose `session` is an agent
       session's number belongs to the last session with that number that started before
       it, as the session's end events do; an event with no `session`, or a bare
       session's, belongs to the last agent session that started before it, and an event
       before every session to the first. An event whose `session` is the number of a
       session that never ran its agent, because its wall failed after the session
       started, is in the Timeline after the list, `timeline-after-list`, as on a run
       whose only session's wall failed. So sessions that overlap in time keep their
       events apart, and each Main session row counts the calls and results of its
       session. The first Timeline has Run started and Policy applied, and the last
       agent session's Timeline has Run ended. Load earlier is in the Timeline of the
       first loaded row, Load newer in the Timeline of the last, and the page keeps 600
       rows across all Timelines. A run with one agent session has one Timeline,
       `timeline`, with every row, and, when a session's wall failed after its start,
       `timeline-after-list`. A session with no exit on a run that ended shows
       Cancelled. A run with no session's start at all, from an older record, has one
       Agent session whose Run the agent has Finished, Result and Model alone.
     - **Save the outputs**: the artifact versions the session's agent saved, by their run
       of the queue (`runs.dispatch_run_id`), such as "proposal Version 3", after Outputs
       saved and the time of the first, and the `push` steps, the host work a run does
       after its last agent session, in the last session. A version belongs to the last
       session that started by its time. It starts at the first push's start and ends at
       the end of the last push; with no push step, it runs from the first version to the
       last. A session that saved nothing has no Save the outputs. A failed push is no
       failed preparation: it adds no cause line, no reason in the meta line and no note
       above the timeline. "How it ended" in the header states what happened at the push
       when no failed result or turn comes first (The header). When the copy of the run's
       work back from the wall fails, "How it ended" reads "The run's work did not come
       back from the machine.", under the same rule; the copy step has no row.

     A prebuild, a run of the queue for the step `prebuild`, builds its image in one
     session that `qory` starts with no agent. That session is the step **Build the
     image**, between Prepare the machine and Remove the machine, with no Agent session,
     Prepare the session or Run the agent. Build the image opens to the session's join,
     **Start the build**, and its wall, then Started and Finished as Run the agent has
     them, the note of a runtime that is not Claude Code as Run the agent has it, and the
     session's Timeline. The join of any other run is Start the agent. A
     prebuild's `image` step, which Forager writes in the session's join after the
     session's start, is in Prepare the machine. A prebuild's `dev.qory.run.built` is
     the step **Save the outputs**, with Outputs saved and the image it reports. A long
     value, such as the image's reference, wraps inside its column. The
     session is read as an agent session whether or not its `dev.qory.session.started`
     has `bare: true`, so its join and wall keep their rows. A failed join or wall fails
     Build the image, with the step's cause line, such as "Start the build failed with
     exit code 1."; a failed session fails it with "Build the image failed with exit
     code 1." for the session's exit code. Save the outputs is then Skipped.

     Save the outputs is failed, with a cause line, when the image was not saved. The
     line shows what happened, with the values that differ in code font, then what the
     reader does, where there is a step to take:

     - The report failed the check that stores the image (`Apiary.Dispatches.Built`).
       Its image is not at the registry address the claim sent the run: "The image was
       not saved: the run reported it at `registry.example.com/northwind/other`, but this
       run saves images only under `registry.example.com/northwind/storefront`." Its
       environment image differs from the one the run was sent, as an address or as the
       image the build started from. A member breaks its form, such as `commit` that "is
       not 40 or 64 lower-case hexadecimal characters", with "Contact support with run
       rn_…". The run's documents have no registry address, as for a run claimed before
       the claim sent one, with "Rebuild **northwind/storefront** to build the image
       again." for a reader who may rebuild the target's environment, else "Ask an admin
       of Main to rebuild **northwind/storefront**." The run is not recorded as a
       prebuild handed over to a machine, with "Contact support with run rn_…".
     - The run failed after its build session exited 0 and sent no report, as `qory` does
       when its check of the build's result fails: "The image was not saved: the build
       finished, but no image arrived." The cause is in the output of `qory`, so the line
       shows where to read it, by reader. An instance admin reads the machine log under
       **Start the machine**. Anyone else reads the log of a pool of the workspace on its
       host, asks an admin of the organisation whose pool it is, or, on Qory Pool,
       contacts support with the run's id.
     - The run was lost or cancelled after its build session exited 0, before an image
       arrived: "The image was not saved: the build finished, but the run was lost
       before an image arrived.", or "cancelled" in place of "lost".

     An Agent session and its Run the agent are open when they appear on a live run, where
     the duration counts up, and closed on a run that ended. They open for a `?seq=` link
     to an event of the session, for j or k with focus on the row (j moves to the first
     event of its Timeline, k to the last), and for the new-events pill. g e, the live end,
     opens the last Run the agent and moves to the last row of its Timeline.
  6. **Remove the machine**, last, shows what the pool's starter reported about the removal
     of the machine (`PreparationComponents.clean_up/3`). It starts at the end of the
     run's dispatch, or the run's end, and takes the time to the starter's `gone` report.
     It opens to Machine removed and the time of that report, Cause, "Run ended" for a run
     that exited or "Keep-alive lost" for a run that was lost (`runs.lost_at`), and Alive,
     from `dispatched` to the `gone` report; each is left out when it does not apply. A
     report that is no `gone` shows "Machine removal requested" or "Removal failed: the
     machine still exists" beside the name, with no duration. With no report, a run that
     has ended and whose dispatch was handed over shows "Waiting for a report" for 15
     minutes after the run ended, counted at render, and then "No removal report", with no
     duration; an open page changes at the 15 minutes without a reload. A run that goes on
     with no report has no such row. A report reaches an open page on the run's topic. A
     run on a permanent machine (a node of kind `node`) that ended has **Machine stays
     registered** as its last row in place of Remove the machine, with no time, as the
     machine is not removed.

  A helper step has no row: a step of the kind `copy`, the copy of the run's work back
  from the wall after the last agent session, and the join and the wall of a bare session,
  such as the one that makes that copy. A wall is a bare session's only when no join of an
  agent session lies between the bare session's start and the wall. A bare session is no
  Agent session. In records from before the kind `copy`, a copy step has no kind. A
  migration sets the kind to `copy` on each step with no kind and the name `copy work
  out`, so such a step has no row either.

  A failed step has a red cross. Once the run has ended, each step after a failed step
  that did not run has a grey row with the word Skipped and no content, such as Start
  the wall, Run the agent and Save the outputs after a failed Start the agent, Save the
  outputs after a failed Run the agent, or Prepare the machine, Agent session 1 and
  Remove the machine after a machine that did not start. Start the wall has such a row
  only for a run with a wall. A step made of steps counts as failed after its steps. A
  step that ran and did not fail clears the failure for the steps after it: after a
  failed Agent session 1, an Agent session 2 that ran has no Skipped row, nor does what
  follows it. A wall starts after its session's start; when it fails, the agent never
  ran, so Run the agent and Save the outputs are Skipped, with no Started or Finished,
  and the run's Timeline follows the list. Remove the machine is green after a failed
  step when the machine was removed, as it ran. A step that did not run and follows no
  failed step has no row, and on a live run no step that has not run has a row.

  While the run is alive, a running row has the word Running, a mark that pulses (still
  under `prefers-reduced-motion`), and in place of its duration a clock that ticks in the
  browser (`<.duration elapsed_seconds= elapsed_at= id=>`), from the row's start, or, for
  Start the machine before the starter's `dispatched`, from the claim. A run's exit closes
  a step without an exit as Cancelled; on a lost run such a step keeps the word Running,
  with no clock and no pulse. A step's row opens on a click to its output, for a reader
  who may read the run's log (`run.read_log`), or the run's log-pruned sentence with its
  date once retention deleted the log lines. The output is its last lines, at most 64 KiB
  and 2,500 lines, each with its number in the step's whole output and its time to a
  tenth of a second ("00:33:07.6", the time of the event the line began in), in a box
  that scrolls; a note above the lines shows that the start is cut. A step that exits
  with code -1 has no exit status, and its line shows no code. A running or failed row is
  open when it appears, Start the machine also while its `machine` step runs or once that
  step failed; the others are closed, and a person's open or close stays. A push step's
  row, and Save the outputs, open when the push fails on an open page, as their `id`
  changes to a new one that ends in `-failed`, so the page mounts them again.

  A failed step has one cause line under its output that states what happened, with no
  advice. The cause line starts with the step's label; when the name qory or Forager
  sent for the step has words beyond its label, the name follows in parentheses, as
  sent, with a set-up command in code font: "Set up the dev container failed with exit
  code 1 (postCreateCommand: `npm ci`)." A join and a step whose name is one word, such
  as qory's `prepare`, have no parentheses: "Set up the dev container failed with exit
  code 1." For an image step named by its image reference alone, the parentheses contain
  that reference: "Pull the images failed (registry.example.com/acme/storefront-dev:1)."
  A run whose pull ended with one of Forager's image codes (`image_missing`,
  `image_access_denied`, `image_rate_limited`, `image_registry_unreachable`) has that
  line too. Under Start
  the machine, for a machine that did not start, the line states the machine's cause,
  such as "Qory Pool did not start a machine within 10 minutes." A run that stopped
  before its first agent session started has no note above the Timeline: the failed row
  and its cause line state what happened. A run whose preparation stopped after a
  session's start, as at a failed wall, has no note about missing session events when no
  agent session ran its agent. When an earlier agent session ran its agent, that
  session's notes stay in its Run the agent: the note about a wall or missing hook
  events, or the note about its runtime. The meta line's reason shows a machine's cause,
  and "How it ended" a step's.

  The heading's time counts only the rows the list shows. It runs from the first row's
  start, Queue the run's for a run a pool claimed, to the end of the last row: the `gone`
  report, else the latest end of the dispatch, the machine's start, a step, a session or
  Save the outputs. While the run is alive it counts up from the first row's start, "4 m
  13 s so far". The page reads the run's preparation again at each flush until it has
  settled: until the session's first item, or until the session started with no step
  running. After that it reads it at each `dev.qory.run.step_started`,
  `dev.qory.run.step_exited`, `dev.qory.session.started`, `dev.qory.runtime.result`,
  `dev.qory.session.exited` and `dev.qory.run.exited`, so a later session's join and
  start, a session's end and a push show on an open page. It also reads it when a version
  is pushed to the run's work item (the work item's artifacts topic), so a version pushed
  with no push step shows at once. The starter's `dispatched` and the redemption of the
  run's code are broadcast on the run's topic, so they show at once. On the Timeline tab
  the page also reads them at each quiet tick (5 s) while Start the machine is running.
  When the first agent session starts on an open page, the timeline moves into Run the
  agent, and the page sends its loaded events again and keeps the count of new events. A
  later agent session's start adds its Agent session with a new Timeline, and the page
  sends no events again: the events after that start go into it.
- **The end reason** is one line of words (`RunComponents.reason_words/1`), the same in
  the meta line, under State in the rail and in the runs list's preview, and in the
  timeline's last item too unless the run was given an outcome: that item says the exit's
  reason, and the others the outcome's
  ([contract-assumptions.md](contract-assumptions.md), How a run ends):
  "time limit reached", "permission to run expired",
  "stopped, no outcome given", "interrupted", "stopped responding", "end not recorded",
  "events refused", "couldn't check whether the run may go on: no answer", "couldn't
  check whether the run may go on: unreadable answer", and for a run that did not start
  its refusal: for a code of a check of the run's settings on the machine
  (`run_configuration_invalid`, `tool_unknown`, `image_unknown`, `image_not_allowed`,
  `image_user_root`, `variable_reserved`, `placeholder_conflict`, `mount_mode_conflict`
  and `mount_contains_forager_files`), "The run's settings did not pass a check on the
  machine (image_unknown).", with the code in mono in the meta line and the rail; for
  `engine_unreachable`, "The machine could not check an earlier run's container
  (engine_unreachable).", the code in mono there too; for any other code, "did not start"
  and the code in mono ("did not start: image_missing"); with no code, "did not start". A run whose starter sent its outcome
  with no state reads "the starter gave no outcome" in the meta line, the rail and the
  preview, after the state's word "Cancelled", with no "as its starter said" sentence.
  None names who or what ended the run. `workflow_not_in_harness`, which qory gives
  when the harness it composed for the run has no skill for the run's workflow, reads
  two sentences: "The run's harness has no skill for the workflow
  explore-a-ticket.", then where the harness came from, from the run's harness walk:
  "The harness comes from the harness file at the root of target acme/web-shop."
  ("repository" in a software workspace), "The harness comes from
  https://git.example.com/acme/harness, stack core." (or "folder" and the path, or the
  address alone), "The harness is the workspace's harness." for a harness section that
  lists modules alone, or "The harness is the Qory harness."; a hidden harness has the
  first sentence alone. The work item shows the same under "The run did not
  start.". qory gives four codes for a read-only run it closes before a session joins
  it: `read_needs_wall` reads "read-only run with no wall",
  `read_needs_setup_outside` "setup runs inside the agent's container",
  `read_needs_no_nested_docker` "image has nested Docker" and
  `read_needs_setup_removed` "setup container not removed". The work item shows the
  fix, then the cause, under "The run ended without a result.": "Set a wall in the
  machine's forager.yaml, then start the run again. A read-only run needs a wall, and
  this machine has none."; "Set wall.setup to outside in the machine's forager.yaml, or
  remove it, then start the run again. A read-only run cannot run its setup inside the
  agent's container."; "Choose an image without nested Docker in the target's
  environment, then start the run again. A read-only run cannot use an image with nested
  Docker." ("repository's" in a software workspace); and "Start the
  run again. The setup container was not removed, so a process in it could still write
  the files.". On the Qory Pool, whose forager.yaml a person in an organisation cannot
  edit, "Contact support." replaces the fix of the first two. Any other code is the
  run's starter's, shown as given with spaces for underscores: "no longer needed".
  A run a pool's claim registered whose machine never started it reads its cause in
  the meta line, the rail and the preview: "No machine was made: <the starter's reason>."
  when the starter released its dispatch, "The pool did not start a machine within 10
  minutes." when the dispatch's lease lapsed, "The machine stopped before it started the
  run." when the machine's log came first, and, for a run lost with its run code never
  redeemed, "The machine did not start the run within 15 minutes of the request."
- **The rail's State and Exit.** State is the state's dot and word, with "Registered only"
  under Pending for a run that registered, or "Ping only" for a run that only pinged,
  stored before the registration replaced the ping, and the end reason's words under it. Exit, on a session's run whose exit was
  recorded, whatever its state, is the runtime's exit as recorded, in mono: the signal
  ("SIGTERM"), else the code ("0", "1"), and "not recorded" for `-1` without a signal,
  the placeholder of an exit that holds no exit status of the runtime's.
- **The timeline's last item** is one kind for every end: "Run ended", then the end
  reason's words, else the runtime's exit ("exit 1", "SIGKILL"; nothing for `-1` without
  a signal, nor for an exit with no code at all), then how long the run ran. Its mark is the state's: a check for Completed, a grey stop for
  Cancelled, a neutral pause for Paused, an amber signal-slash for Lost and a red x-mark
  for Failed. A run that paused after it pushed its questions or a proposal ended
  Completed, and its last item is a completed run's, with no reason. A run that did
  not start ends on "Run did not start" and the refusal's code in mono, with the red
  x-mark.
- **The announcer** (`#run-announcer`) says a change of state at once: "Run started.";
  "Run completed after 12 m 04 s.", or "Run completed."; "Run failed with exit 1.", "Run
  failed with SIGKILL.", or "Run failed." where the header says no exit; "Run did not
  start."; "Run cancelled: time limit reached.", or "Run cancelled." with no reason; "Run
  lost: stopped responding." for a run whose exit's state is `lost`, and "Run lost. No
  heartbeat for 90 s." for one the lost-run check marked; a paused run in the words of
  its paused line, "Paused: every key of Northwind Claude is in cooldown until Fri 14:00.
  It continues in run 15."; and "Heartbeats resumed." when a quiet run is heard again. A
  state stored under an older name is said as its new state.
- **A run through a gateway** looks as any run: its Machine or pool is the machine or pool that registered it,
  and its Host the machine the runtime ran on.

## The terminal

`<.terminal>` in `RunPageComponents` is dark in both themes: the recorded output's colours
are written against a dark ground. It fills the window below the tab bar, never under
380 px. It has two views, **Transcript** and **Raw**, as a two-button segment at the bar's
start when the run has both.

- **Transcript** (`ApiaryWeb.TranscriptComponents`) is the session drawn by the LiveView
  from its runtime events (`dev.qory.runtime.*`), in sequence order, as HTML in the mono
  font. It reads no runtime's output format, so a runtime whose Forager descriptor maps
  its output to these events needs no change here. Its lines:
  - a prompt: `❯` and the prompt, from `runtime.prompt_submitted`, or a text whose `role`
    is `user`, such as a subagent's prompt (the Timeline shows it as a Prompt row);
  - a tool call: `⏺`, the tool and the first line of its `summary` in brackets
    (`⏺ Skill(harness:greet)`), or the tool alone without one; under it, after `⎿`, the
    first 3 lines of the result the runtime gave the model (`runtime.tool_result`), then
    "%{number} more lines", which opens the rest, read whole, and "Show less", which
    folds it again. A string result shows as written; of an array of blocks, each text
    block's text shows, and each other block its type in brackets. A call with no result
    has no line under it. A denied call shows `⎿ Denied:` and the reason, or "Not run:
    denied" without one, on one line; a failed call shows its error in the failure
    colour. When lines of another agent arrived between a call and its result (a
    subagent's lines under its Task call), the result is drawn after them, at the call's
    indent, by sequence and agent alone;
  - a text: `⏺` and the text as Markdown through `Apiary.Sources.Body`, as on a work
    item, with each line kept (`hard_breaks: true`), and no HTML of the text; thinking
    with text is folded under "Thinking", and empty thinking is left out;
  - the result: `✓` or `✗` and its outcome, turns, duration and cost, without its text,
    which the text line before it shows.

  A subagent's lines are indented. A text or result the session cut at 64 KiB ends with
  "Cut at 64 KiB. Raw has every byte.". Each line read from the session's output has a
  **Raw** link at its end, shown on hover and on focus, named "Show line %{number} in
  Raw": the server finds where that line starts in the log (`Record.log_offset/5`,
  counting the session's stdout chunks outside steps, as Forager counts `line`), and Raw
  is read again with that line marked at the top of the screen; a Raw that showed stderr
  alone shows both streams. The Transcript is a window of the items, as the Timeline is:
  "%{number} earlier events" and "Load newer" load more, a live run adds its lines as
  they arrive, and the end is followed while the reader is at it. A Timeline link
  (`?seq=`) brings its line into view. Wrap is off as the Transcript opens: a tool's line
  and its result's lines are cut at the box's edge with `…`, and a text wraps; Wrap on
  wraps every line.
- **Older runs.** A run recorded before Forager sent texts, results and denials shows
  its tool lines, and each turn's last message (`turn_finished`) in place of the texts; a
  tool's line opens to what the tool returned, as JSON. With neither texts nor turn ends,
  the result shows its text.
- **Raw** is the log's bytes in xterm.js. The `Terminal` hook reads them from the run's
  log endpoint and hands them to xterm.js as `Uint8Array`s, never decoded strings, in
  slices per frame so a long log does not block input, and interprets none of them. A
  sequence that scrolls, inserts or deletes more than 10,000 lines, or repeats a character
  more than 65,536 times, is dropped, as no screen needs it and carrying it out held the
  page for seconds. The bytes never cross the LiveView socket: the LiveView sends the
  foot's numbers and a signal that the log advanced. xterm.js is vendored under
  `assets/vendor/xterm`, built as a separate bundle and loaded the first time Raw shows,
  by no other page. The screen is `role="log"` with `aria-live="off"`, with the note under
  the box.
- **The view it opens in.** A run on pipes with a Transcript opens in Transcript, or in
  Raw when that is the reader's choice, kept in `localStorage`. A run on a pseudo-terminal
  opens in Raw, as its log is cursor movement, and so does a run with no runtime events.
- **The recorded width is kept.** A run whose record says its pseudo-terminal's size is
  drawn at those columns and rows, centred only inside the box's darker ground, which
  fills the column; it scrolls inside the box when it is larger. A run on pipes is fitted
  to the box, with Wrap.
- **The bar**: the view, then Raw's stream (stdout, stderr or both), search (`/`), follow
  (End) and wrap, which show only in Raw; in the Transcript, **Jump to end** (End), which
  loads the lines after the window and follows the end, and **Wrap**; the **text size** (A−, A+, 11 to 18 px, and Fit,
  the largest size at which a recorded screen's columns fit), a reading preference kept in
  `localStorage` for both views; download; **Focus** (`f` outside a field; Escape
  leaves), a class on the root that folds the shell, the header, the tabs and the rail
  away so the box takes the window; and **Full screen**, the browser's, on the box, shown
  only where the browser has it. A narrow box names its buttons on hover only (a
  container query), so the bar never wraps. Search reads Raw's screen, so typing in it
  shows Raw ("Search the log. Searching shows the Raw view."); with no match, an ended run
  shows the start of its log.
- **Access and retention.** The tab is `run.read_log`'s, as tool results are log content.
  The Transcript follows the events' retention and Raw the log's, and the log goes first:
  a run whose log was pruned shows the log's pruned notice and the Transcript alone.
- **No output.** For a run with neither a log nor runtime events, the column shows an
  empty state in place of the box.

## The stages canvas

`<Canvas.canvas>` in `ApiaryWeb.StagesLive.Canvas` draws a process's stages with React
Flow (`assets/js/canvas.js`, a separate bundle loaded on first mount). Workspace settings ›
Workflows, Instance settings › Workspace types and a workspace type's page use it.

- **The column.** The stages lie top to bottom on a dotted ground (dots 20 px apart, the
  theme's text colour at 22 %), each a 360 px card with its name (18 px), its description
  where it has one (14 px, muted, plain text with its line breaks, wrapped and cut to
  three lines, in full in its title; a read-only stage panel shows it whole), its
  workflows and loops (16 px; a loop is a dashed box inside the card, labelled with its
  rounds), its gate line and its alert lines, joined to the next card by an arrow. The
  cards are drawn at zoom 1; a pinch or the zoom buttons zoom from 0.75 to 1.5. You
  reach stages out of view by scrolling the canvas; there is no "more" control.
- **Edit mode** (`mode={:edit}`): a "+" above the first card, between two cards and below
  the last adds a stage there. You drag a card to a new place, or move it one place with
  the up and down arrow keys; Enter opens it in the inspector beside the canvas.
- **View-only mode** (`mode={:view}`): no "+", no drag and no move. With
  `selectable={false}` a card opens nothing and Tab passes it by.
- **The buttons**, at the canvas's top right in both modes: Zoom out, Zoom in, **Focus**
  (`f` outside a field; a class on the root that folds the shell and the sidebar away so
  the box takes the window; Escape leaves) and **Full screen**, the browser's, shown only where the browser
  has it.
- **Size.** In a `.q-canvas-fill` box (app.css) the canvas takes the rest of the window,
  as the terminal does: from 1024 px the page is the window's height, every element down
  to the box stretches, and the box takes the rest, never under 380 px. A `.q-canvas-side`
  after the canvas in that box (the inspector, or a side panel) sits beside it, 30rem wide
  unless `--q-canvas-side` sets another width, and scrolls; below 1024 px it goes under
  the canvas, which is then 70 % of the window tall. Focus and Full screen show the whole
  box, the side too. Outside such a box the canvas is as tall as its column. A box that
  is the page's first element, or comes right after the shell's notices while no notice
  shows, starts at the top bar, with no page padding above it.
- **The settings pages.** Workspace settings › Workflows and Instance settings › Workspace
  types each have two tabs under the page's title (`page_tabs/1`, `place="section"`):
  **Stages**, at the page's address, is the canvas with the inspector beside it in a
  `.q-canvas-fill` box, right under the tabs; **Details**, at `?tab=details`, starts with
  the page's sentence, then every other setting (on Workspace types the type's Name,
  Summary and How it works first) and the history. The version line, **Save**, **Save
  as trial** (Workspace settings only) and **Discard changes** are at the right end of the
  tabs' row on both tabs: one draft has the edits of both, and a switch of tabs keeps it.
  Details' **Default machine type** and a workflow's **Machine type** in the inspector are
  selects of the instance's machine types by name ("Large: 4 vCPUs, 16 GiB"), each with
  its key as its value: the default's first, "Default (Standard)", and a workflow's
  "Workspace default (Standard)", with "Default (Standard)" also for a workflow set to
  `default`. A key that no type has is the first option's value, with its words, so a
  save keeps it; a value that breaks the key's pattern stays as one more option. A member
  who cannot edit reads the default's words and a type's name, such as "Large", in Details
  and in the stage's Sequence. Its hint on Workflows is "Workflows that
  pick no machine type run on this one. The people who run this Qory Apiary add machine
  types."; on Workspace types, "New workspaces of this type start with this default. Add
  machine types in Instance settings › Machine types.", with a link. The page exists
  wherever this one does, because `workflow_model` needs `factory`.
  Workspace settings adds a row under the tabs for owners and admins (`process.edit`), on
  both tabs:
  **Export process.yaml** downloads the current version, with no draft or trial. The text
  beside the button is "Commit this file to a harness repository. Only new workspaces made
  from it use it.", and "Gates that list people export as all members." follows it when a
  gate of the current version lists people. The file has each machine type key as the
  version has it, with no line about it.
- **The inspector.** A stage's form has fields for the stage's name and description. A
  member's read-only panel has the stage's name and, when the stage has one, its
  description. Both then have four boxes (`sect/1`, `q-sect-side`) in the order a stage
  works: Inputs, Sequence, Outputs and Gate.
  Each workflow is a row with its name, then one line in a native `<details>`: **Machine
  type: Workspace default (Standard)**, ending in **Change**, or **Close** while open. Its
  fields stay in the form while closed. A refused machine type shows on that line while
  the fold is closed. A key that no type has shows "Pick a machine type: no type has the
  key browser." under that line, and in the fold, above the picker, the notice "Pick a
  machine type for make-mockups." with the `process.yaml` that sets the key and the type
  the runs start on; on Workspace types the notice is the line.
  The check's words are in the fold, and on the row for a screen reader and as a title;
  the cross keeps its words on the row.

## Words

Every visible or announced string goes through Gettext in engine words, one whole sentence
per msgid, and markup inside a sentence goes through `ApiaryWeb.RichText`; the rules are
in [lingo.md](lingo.md). A page says organisation and workspace as plain words, and names
the product Qory Apiary. Where an instance admin set a name in Instance settings › General
(`Apiary.ProductName`), it replaces Qory Apiary in the browser title, the Qory Apiary
menu's button and names (which, where no name is set, show the edition's name,
`c:ApiaryWeb.Edition.product_name/0`, Qory Apiary in the core's), the log-in, sign-up,
set-up and welcome pages (`Layouts.auth`: the name beside the mark, the brand panel's name
and line, the headings, and the sentences there that say "this Qory Apiary", which then
name the instance), the button of the page `/docs` shows when the docs are not built, and
every email's from-name, subject and body. Those places then also say "Powered by Qory
Apiary": the sidebar's foot (The shell), under the form of every page with the brand panel
(`#powered-by`), and each email's last line.
Everything else keeps Qory Apiary: the docs, the console's other sentences that say "this
Qory Apiary", the sentences where Qory Apiary acts or is what a machine connects to, and
the Activity page's.

- Plain and exact: second person, present tense, sentence case. Full stops on sentences,
  none on buttons, labels or headings. No exclamation marks, no "oops", no "successfully".
- A button says what happens ("Send me a log-in link"); a toast says what happened
  ("build-01 is revoked."); a confirm states the consequence, then whether it can be
  undone. Deleting a workspace or an organisation asks for its slug, and deleting an
  account for its email, typed, and the
  button stays disabled until it matches; a control that cannot act, such as the only
  owner's Delete account, is disabled and the page says why beside it.
- The page says what the record says and infers nothing. A value the record lacks reads
  "n/a"; a key that never posted says so.

## Accessibility

- **Focus.** One global `:focus-visible` ring in `--q-ring`; a control never loses its
  focus style without a replacement. The tab order is the visual order, with no positive
  `tabindex`. A failed submit puts the caret in the first invalid field, or the first
  radio of an invalid radio group. A live navigation gives focus to the settings section's
  title (`#settings-section-title`, `tabindex="-1"`) where the page has one, else to the
  new page's `<h1>` (`tabindex="-1"`, as `<.header>` and `page_header/1` render it),
  unless the page put it somewhere itself, so a screen reader says where the reader
  landed. After any LiveView update that removed the element that had the focus (Cancel,
  Save, an inline confirmation, a × or Show all), the focus goes the same way, but only
  when it has fallen to `<body>`: a page that moves the focus itself (the `FocusOn` hook, a
  `phx-mounted` focus, `JS.focus`) keeps it. The focused title is described by the
  organisation's notices (`#shell-notices`, the edition's `:notices` slot) where there are
  any, so a screen reader reads them though they sit above it.
- **Keys.** A shortcut of a single key (/ for search, `[` for the fold, `a` and `?` on
  the policy pages, `f` on the terminal, the timeline's letters) works only outside a
  field, and only while Preferences' **Keyboard shortcuts** is on, as it is unless the
  reader turned it off (WCAG 2.1.4): a reading preference of the browser
  (`qory:shortcuts` in `localStorage`), written on `<html>` as `data-shortcuts="off"`
  before the first paint, which every hook asks through `singleKeys()`
  (`assets/js/hooks/shortcuts.js`). A shortcut with ⌘ or Ctrl, such as ⌘K, asks nothing.
- **Names.** An icon-only button has an `aria-label`. A row action names its object
  ("Revoke build-01") while its visible text stays short. A field has a visible label, and
  its error is tied to it with `aria-invalid` and `aria-describedby`. Each `<nav>` of the
  sidebar has a name: its heading, Main for the first group, else its first
  entry's; the second column is named by its heading, the level (Workspace settings,
  Organisation settings, Your settings, Instance), not by the place beneath it, at every
  width, its heading a button below 1024 px. The current entry is marked
  by `aria-current`, `"page"` for the exact page and `"true"` for its parent (The shell).
  No control sits inside another: a timeline item's number inside its
  `<summary>` is text that carries its path, which `c` copies.
- **Live regions.** A page that changes while it is read has one polite announcer
  (`#run-announcer`, `#overview-announcer`, `#policy-announce`) for the few things worth
  saying. Ticking text, a filling timeline and the terminal are `aria-live="off"`. Toasts
  are `role="status"` or `role="alert"`; an info toast leaves after 5 s, and hovering or
  focusing it holds it. A copy is announced politely: a button by a live span inside it, a
  row's copy by the shell's one `#copy-announcer`, never a live region a row.
- **Motion.** Motion shows cause and effect for what floats; layout, rows and streamed
  inserts never animate. The only loops mean "still being written": the spinner, the
  skeleton and the alive ripple. Under `prefers-reduced-motion: reduce` the global block
  in `app.css` zeroes every duration, the loops stand still, and a hook that scrolls uses
  `behavior: "auto"`.

## Phones and touch

The breakpoint is 768 px (Tailwind's `md`). Below it the sidebar is the drawer, which
scrolls as one piece and holds the sidebar alone under a head that opens the
organisation and workspace menus where there are any (The shell), the gutter is 16 px,
controls are 40 px high and inputs take 16 px text so the browser does not zoom. The
second column is a column from 1024 px and, below it, at every width, one disclosure under
the top bar, `[ Workspace settings · Main ▾ ]`, whose links open in place. On a touch screen (`pointer: coarse`) a small control gets a 40 px hit area
whatever its drawn size. At 320 px wide, and at 200% zoom, the page never scrolls
sideways: tables, code, the filter bar and the terminal scroll inside their
containers.
