# The console's pages

The rules the pages of the console follow, for a contributor who adds a page or changes
one. The words on them are in [lingo.md](lingo.md); where the code lives is in
[architecture.md](architecture.md).

## The shell

Every page behind sign-in renders inside `ApiaryWeb.Layouts.app/1`, which takes the
page's active navigation item (`nav`), the counts the sidebar shows (`counts`), the width
of its column (`width`), on a page of a level's settings the level's sections and its own
(`sections`, `section`), on a list narrowed to one target that target (`narrowed`) and, in
`crumb` slots, the page's own segments of the breadcrumb. The shell shows one scope's
sidebar at a time, the one the page belongs to, or, on a person's own page and an Instance
page, the one the person came from (Two levels, below).

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
  then the workspace, each a link to its home, and the page's own segments, a target or a
  record, the last one the page with `aria-current="page"`. A page of a workspace or an
  organisation starts them with its section's name as the sidebar words it: a link to the
  section's page on a page under it (`Acme / Main / Runs / Run 0191f2a4`, also where that
  run is not found, and `Acme / Main / Runs` where the address is no run's id), the page
  itself on the section's own page (`Acme / Main / Runs`, `Acme / Main / Overview`,
  `Acme / Main / Policy`, `Acme / Overview`, `Acme / Audit log`). A thing with tabs (a
  target, a node, a run, an integration) is the page itself on its first tab and a link
  to it on the others; on a page of a level's settings the frame writes the level (`#breadcrumb-settings`, "Workspace settings" or
  "Organisation settings", a link to its General) and the section (`#breadcrumb-section`,
  the page itself, or a link where segments follow it), so the page adds only what follows
  the section (`Acme / Main / Workspace settings / Secrets and variables / New secret`); on
  a person's own page Your
  settings, its section and the page's own segments, such as an edition's `Your settings /
  Organisations / New organisation`, and on an Instance page Instance settings and its
  section the same way, the section a link where segments follow it), then **Search or jump to**,
  **New** and the **account menu**. The bar has no mark: Qory Apiary is the sidebar's
  foot. A page's title stays its `<h1>`; the breadcrumb is navigation. A page without a
  person has no sidebar, and the Qory Apiary menu opens downward from the bar's left.
- **The switcher.** With more than one place to go, or an edition's entry after the places
  (`ApiaryWeb.Edition.switcher_entries/1`), the chevrons beside the organisation and the
  workspace open one dropdown under them (a disclosure: the chevron's `aria-expanded` and
  `aria-controls`, the panel a named `role="group"`; the `Switcher` hook): a search that filters
  as the reader types, the places opened last (kept in `localStorage`), then each
  organisation with its workspaces, a link to each at the section the reader is on where
  that workspace has it, else its overview (a section of a feature goes through
  `/:org/:workspace/switch/:section`, `ApiaryWeb.SwitchController`, which asks the
  destination's own scope when it is followed), and
  the edition's groups of places under their own headings
  (`ApiaryWeb.Edition.place_group/1`), each folded behind its heading, a button with the
  group's count, unless the reader's place is in it; a search opens every group it finds a
  place in. ↑ and ↓ move, Enter opens the first match, Escape
  closes and gives focus back. With one place the segments are links and nothing more.
- **Search or jump to** (⌘K, Ctrl+K, and / outside a field) is a `<dialog>` under the
  `Palette` hook, which asks `ApiaryWeb.JumpController` what matches, 150 ms after the
  reader stops typing, at the sidebar's level: `/:org/:workspace/jump` where the sidebar is
  a workspace's, as on a person's own page or an Instance page shown with one, else
  `/:org/jump`. It finds the pages of the navigation, the sections of each
  Settings and of the Instance, and Preferences' theme and shortcuts, each
  named by whose it is where two scopes share a name (Workspace overview, Organisation
  settings › People, Instance settings › Configuration; an edition's entry by its `long_label`) and found by its other words too (members, audit, dark), targets,
  runs by id or title, places, what New offers and, for what is typed, the deletions the
  reader may take. Every word of it comes from the server; words Forager reported are written
  as text.
- **New** offers only what the reader may do where the page is
  (`ApiaryWeb.Layouts.new_entries/2`): on a workspace's page New node, New node pool, Add
  integration (to Integrations' cards, `#add-part`), New secret and New variable, then,
  on every page, Invite people; before the core's, whatever the edition
  offers there (`ApiaryWeb.Edition.new_entries/2`); each entry asked of the workspace or
  the organisation as its place says. **The account menu** holds who they are, their email
  over "Your personal account" (`#user-menu-account`; an account has no name), then
  Settings (`#user-menu-settings`, the person's own, `/users/settings`) and Your
  organisations, the theme (Auto, Light, Dark), then Log out; an edition's entries follow
  the core's of their group (`ApiaryWeb.Edition.account_menu_entries/1`), its group
  `:instance` after the theme. Nothing in it is about Qory Apiary itself, and so not the
  Instance level: Instance settings is the Qory Apiary menu's (below).
- **The sidebar** holds the scope's pages and nothing else, in groups, each a `<nav>` with
  its own name: a workspace's Overview, then Record (Runs, Targets, Nodes) and Guard
  (Network access, then Policy, which carries the policy's mode word alone, how many
  targets set their own in its title; without `security` Network access alone, the record
  of it), then the targets the person pinned (`counts.pins`, the first seven in the
  order pinned, `Apiary.Targets.list_pins/2`; on a target's page its pin is the current
  entry); an organisation's
  Overview and Audit log, then the edition's groups (`ApiaryWeb.Edition.nav_sections/0`);
  the person's Account, Preferences and Organisations under Your settings, the sidebar of
  their own pages only where there is no workspace to show (Two levels, below). It is
  never replaced: a page of a scope's settings keeps the scope's sidebar. A group whose
  feature is off is absent, not greyed.
- **The current entry.** `aria-current="page"` marks only the entry of the exact page; a
  parent of the page carries `aria-current="true"`: the sidebar's Workspace settings or
  Organisation settings while its sections are the second column, whose entry is the exact
  page, and a second column's section on a page under it, one that passes `crumb` segments
  (Invite people, New secret). A section's tabs are the section's own page: the column
  marks it as the page on each.
- **The sidebar's foot** holds the scope's settings, named after the level: **Workspace
  settings** (`#nav-settings`) or **Organisation settings** (`#nav-organisation`), never a
  bare Settings, and so its tooltip while folded; the current entry on every page of them
  (General, or an entry of the section `:settings`, such as People), marked as their
  parent (The current entry, above),
  then, under a rule, **the Qory Apiary menu** (`#brand-menu`): the mark, the name and the
  version, opening upward to what is about the product rather than the person: first, only
  for whoever may open a section of the Instance level
  (`ApiaryWeb.Layouts.instance_sections/1`, read with the navigation's counts), **Instance
  settings** (`#brand-menu-instance`), leading to the first, under it a rule; then Docs,
  Changelog (on an instance with every feature), a rule and Source on GitHub; and at the
  right of it the fold. Folded, and from the bar on a page without a sidebar, it is the
  same menu.
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
  focus; a navigation renders it closed. The drawer holds the sidebar alone. The level
  leaves the page: a settings page's `<h1>` is its section. Each keeps the ids its
  list had: `#settings-tabs` and `settings-tab-<key>` for a level's Settings,
  `#nav-group-account` and `nav-<key>` for a person's, `#instance-tabs` and
  `instance-tab-<key>` for the Instance's. A level with fewer than two sections gets no
  second column, and Runs, Network access and Targets never get one. A person's own page
  and an Instance page keep the sidebar the person came from, the workspace the session
  remembers; with no workspace, the person's sidebar is their sections alone. A thing's
  own page, a target, a node or a run, keeps its tabs (`PageComponents.page_tabs/1`), and a
  node's Settings tab lists its few sections in the page.
- **Narrowing.** On Runs and on Network access narrowed to one target, the sidebar's Runs
  and Network access carry the target (`Layouts.app/1`'s `narrowed`, built with
  `Layouts.narrowed/2`): its path, and its system only where two systems share the path,
  each entry's accessible name and tooltip saying so ("Runs, narrowed to acme/shop",
  "Network access, narrowed to acme/shop"). Nothing else carries it, and the palette's Go
  to never does.
- **The sidebar folds to icons** from 768 px, by the fold (`#sidebar-collapse`, an icon
  button named Collapse sidebar, or Expand sidebar while folded, in its label and its
  tooltip) or the `[` key; the fold is a reading preference in `localStorage`, set before
  the first paint by the root layout's script, and while folded each item's name is its
  title. Folded, the foot is the fold over the mark alone, which still opens the menu,
  upward and to the right; the groups are split by rules, their headings gone.
- **Below 768 px the sidebar is a drawer** behind the bar's Open menu button, its head a
  Close menu button and its foot the same, without the fold. Open, it is a modal dialog
  (`role="dialog"`, `aria-modal`). The `NavDrawer` hook moves focus into the drawer, makes
  the top bar, `#shell-content` and Skip to content inert and stops the page scrolling
  behind it; the scrim, Escape, the Close menu button and any navigation close
  it, and focus returns to the menu button. It scrolls as one piece, its Close menu button
  kept at the top, so on a short screen the foot never squeezes the main entries. It holds
  the sidebar alone; on a settings page the foot's Workspace settings is drawn lighter, the
  page's parent, while the disclosure under the bar (Two levels, above) names the level
  and lists its sections. The bar names the last segment of the breadcrumb only, and before
  it, on a page under a parent, the parent as a link back, a chevron before its name
  (`‹ Runs / Run 0191f2a4`, `‹ Secrets and variables / New secret`): the item of the one
  breadcrumb the wider bar shows too (`q-trail-up`), so a screen reader hears one trail. A
  section's own page shows its name alone. On a core Instance page, which has one section
  and so no disclosure, it keeps both, `Instance settings / Configuration`.
- **Landmarks.** A Skip to content link is the first thing in the tab order and targets
  the one `<main id="main">`. A page has one `<h1>`, the title of its header
  (`PageComponents.page_header/1`, or `<.header>`), which also holds a one-line
  description and at most one primary and one default action, or, where the page makes
  two peer kinds (Nodes: New node and New node pool), two default actions and no
  primary. Card titles are `<h2>`.

## No modals

Nothing opens over a page but **Search or jump to**, the palette (above), the one overlay
the console keeps. Every other act happens on a page, in place:

- **A form is a page** of its section at a path of its own, never a dialog over a list:
  New secret, New variable, Invite people, New node, an export. Its
  breadcrumb ends with the section and the page; its title is the act and what it acts
  on, with one sentence under it; its form fills the 720 px column, its first field takes
  the focus, and its foot is the primary button with Cancel back to where it was opened
  from (`SettingsComponents.save/1`, `cancel`). Its header has no Back link: Cancel and the
  breadcrumb lead back (`PageComponents.page_form/1`, `page_form_foot/1`). A save goes back
  with a flash; a refused one stays, the error under its field. What a save shows once,
  such as a generated key's secret, it shows on the page the save leads to, never again
  once the reader leaves it.
  The pattern is Add
  integration's (storybook, Screens); A form is a page, under Settings, says the rest.
- **A confirmation is in place** (`<.inline_confirm>`, Components): a row's Delete,
  Revoke, Remove, Suspend or Clear turns that row into the question, "Delete
  FORGE_TOKEN?", what is lost, "Yes, delete" and Cancel; a danger zone's line expands
  under its sentence, with the field to type where one is asked; a page's own setting,
  such as the policy's mode, opens its choices in place and asks under them. Each keeps
  the path it had, which opens the page with that confirmation showing and never acts by
  itself; Cancel and Escape go back.
- **What is undone as easily as it is done acts at once**, with a flash that says what it
  did: Lock and Unlock of a variable, a plain Remove of a policy rule. It asks in place
  only when something is lost or set aside.
- **What only reads** is a page too, or opens in place under its row: the targets that set
  a variable, the keys of the policy pages (`?`).
- **Menus, Filter, the switcher and Jump to date** drop down under their button: a
  disclosure, its button's `aria-expanded` and `aria-controls`, its panel a menu or a
  named group, closed by Escape or a click elsewhere. They are no dialog either.

## Settings

Configuration is not navigation: what is set up once and changed rarely lives in the
settings. There are five kinds, on the model of GitHub's repository, organisation and
personal settings: a workspace's, an organisation's, a node's, a person's and the
instance's. Each is a place of its own, reached from its own scope, that lists its own
sections and no other kind's: no "Elsewhere", no link across. A navigation item never
replaces the navigation it is in.

- **A workspace's** (`/:org/:workspace/settings/…`), from the workspace sidebar's
  Workspace settings: General (name, slug, and its danger zone), People (`/settings/people`,
  `ApiaryWeb.MemberLive.Workspace`: who reaches the workspace and at what level, read
  only, on the row spec of the organisation's People, the edition's `:member_access`
  beside each name; no suspended membership, which reaches nothing), Integrations
  (`/settings/integrations`, `ApiaryWeb.IntegrationLive.Index`: what the workspace sets
  up, never Qory Apiary's own settings, as its subtitle says; one list, Set up in this
  workspace, in the groups' order, each row its name, its kind, Agent, API or Program (one
  added from a release), a program's version and Applies to, where it applies; then,
  for whoever may change it, Add an integration, a card for each thing to add by name, its
  kind a small muted word and one line about it, in three groups, each an `<h3>`, a
  sentence where it has one and a list its heading names: Agent (the runtimes of
  Forager's catalogue), Outside APIs (the built-in APIs, the workspace's own
  custom APIs, then Custom API…) and Programs (the named releases,
  `ApiaryWeb.IntegrationLive.Named`, then From a release…); a card's act opens its form with its
  item chosen, `?runtime=` or `?definition=` (a named release's opens Add from a release,
  its source filled in, `?source=`), an unknown one opening the form as it starts; the
  forms are Set up an agent, Set up an API and Add from a release; an item's page says its
  kind under its title; each page says once that a run receives only
  its security policy) and Secrets and variables (`/settings/secrets`,
  below), each with `security` and for a reader of it (`connection.read`, `secret.read`),
  and Runs (`/settings/runs`: how long the workspace keeps runs, their events and their
  logs; `/settings/retention`, its path before, sends on with its query). A workspace's
  keys are its nodes' (Nodes, below): `/settings/keys` and `/:org/:workspace/keys`,
  the paths of the Access keys page that was removed, are unknown paths, 404.
- **An organisation's** (`/:org/settings/…`), from the organisation's pages (the
  breadcrumb's organisation leads to its overview, whose sidebar has Organisation
  settings): General
  (name, slug, owners, and its danger zone), People (`/settings/people`: members,
  found by their email with Find a person, `?q=`; invitations, suspensions; Invite
  people, the section's action, is a page of it at `/settings/people/invite` (A form is a
  page, below), its one field the email address, and a sent invitation goes back to
  People with a flash; removing, leaving and suspending, each from a member's ⋯ menu, are
  confirmed in place, the member's row turned into the question, what happens, Yes,
  remove (Yes, leave, Yes, suspend) and Cancel (`inline_confirm/1`), at their paths
  `/settings/people/:id/remove` and `…/suspend`, whose Cancel or Escape goes back to
  People), Workspaces
  (owners and admins; each with its targets, `Apiary.Targets.count_by_workspace/1`;
  `SettingsComponents.workspace_list/1`, which an edition's page over the same list
  renders too, with the edition's way of adding one in the section's actions, the
  `:workspaces_heading` slot), and the edition's sections
  (`ApiaryWeb.Edition.settings_tabs/1`). The audit log is not a section of them: it is a
  page of the organisation's sidebar, beside its overview (`/:org/audit-log`,
  `ApiaryWeb.ActivityLive`; `/:org/settings/audit-log` and `/:org/activity`, its paths
  before, send on with their query). From a workspace the palette's Go to, New ›
  Invite people and, for whoever manages members, the workspace People's Manage people
  lead there too, since membership is the organisation's; nothing else in a workspace
  does.
- **A node's** (`/:org/:workspace/nodes/:node_id/settings`), the last tab of the node's
  page (Nodes, below): General (name, kind, a pool's instance limit, and its danger zone).
  The page's header is the node's, so the section list and the section sit under the
  tabs without a heading of their own (`SettingsComponents.layout/1`, `kind={:node}`,
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
  itself does: the edition's sections
  (`ApiaryWeb.Edition.instance_sections/1`), then, for the instance's admins, the core's
  Configuration (`/instance/configuration`, `ApiaryWeb.InstanceLive.Configuration`, its
  `<h1>` Configuration), read only: what whoever runs Qory Apiary set, as Qory Apiary read it
  when it started, each value with the setting it is set by. Anyone else is answered not
  found. The sidebar stays the one the person came from. In the core Configuration is the
  one section, so there is no second column; an edition's sections add to it, and with two
  or more they are the second column (`#instance-tabs`, `instance-tab-<key>`).

A workspace's and an organisation's settings keep the scope's sidebar, its Workspace
settings or Organisation settings the current entry, marked as the parent, and are one
section a page (`ApiaryWeb.SettingsComponents.layout/1`, or
`ApiaryWeb.PageComponents.settings_page/1`): the section's title is the page's one `<h1>`
(20 px, `#settings-section-title`; `heading`, the level's h1 before, is ignored), one
sentence of what it is for, then its content; the frame names the level, in the second
column's heading, the breadcrumb and the browser title. Content is a 720 px column for
forms and 960 px for a list (People, a workspace's and an organisation's, Secrets and
variables).
The list of the kind's sections is not in the page but the frame's second column (Two
levels, under The shell; `#settings-tabs`, `settings-tab-<key>`): the page reads them when
it mounts (`sections/2`) and passes them to `Layouts.app/1` as `sections`, its own key as
`section`. It is labels without icons, muted, the current one in the text colour on a
light fill, with a count where it helps (an organisation's People, from the navigation's
`counts`); below 1024 px it is the disclosure under the top bar (Two levels,
under The shell). A section is flat, no card (Integrations' Add an integration, three
groups of a card per thing to add, aside): its fields straight under its heading
(`SettingsComponents.part/1`, an `<h2>` where it has more than one part, such as Owners;
the danger zone's lines are `<h3>`s), the fields as wide as the column, and at the foot of
a form its one button, primary where it is the section's main action, beside one muted
line (`SettingsComponents.save/1`). A section the reader may not open is not in the list,
and its path sends them to General with its own sentence of why.
The breadcrumb names the level and ends with the section, both written by the frame
(`Acme / Main / Workspace settings / Runs`, `Acme / Organisation settings / People`);
a person's own page starts with Your settings and an Instance page with Instance settings,
then the section (The top bar, under The shell). The browser title is the most specific first, the
page's words, the level, then the workspace's name and the organisation's
(`SettingsComponents.page_title/3`): `Runs · Workspace settings · Main · Acme · Qory
Apiary`, `People · Organisation settings · Acme · Qory Apiary`, `Account · Your
settings · Qory Apiary`, `Configuration · Instance settings · Qory Apiary`.

**A form is a page.** Creating or changing one thing is a page of its section at a path of
its own, never a dialog over the list, on the pattern of Add integration (storybook,
Screens): the second column stays beside it, its section the current one, marked as the
parent (`aria-current="true"`); the breadcrumb ends with the section and the page
(`Acme / Main / Workspace settings / Secrets and variables / New secret`), each segment
before the page a link back, the page adding only the segments after the section; the
section's `<h1>` is the page's title, the act and what it acts on (New secret, Change the value of FORGE_TOKEN), with one
sentence under it of what the page does; the form fills the 720 px column, its first field
takes the focus, and its foot is the primary button with Cancel beside it, a link back to
the list (`SettingsComponents.save/1`, `cancel`). A save goes back to the list with a
flash; a refused one stays on the page, the error under its field. The breadcrumb's last
segment is the act alone (New secret, Change value), and the browser's title the page's
(`New secret · Workspace settings · Main · Acme`).

**The danger zone** ends its scope's General page, and Account, GitHub's way
(`SettingsComponents.danger_zone/1`): after a rule, the heading Danger zone, the page's
only red words, then a line for each act that cannot be undone (`danger_action/1`), its
title, one muted sentence of what it does and what cannot be undone, and at the right a
default button in the error colour, Delete organisation…, Delete workspace… or Delete
account…. No box, and never an entry of a list. **Its confirmation is inline, never a
dialog**: the button is a patch to a path of the act's own, `/:org/settings/danger`,
`/:org/:workspace/settings/danger`, `/users/settings/delete` and a node's
`/nodes/:node_id/settings/delete` (the older `/…/settings/delete` paths open the same),
and there the line expands in place under its sentence
(`SettingsComponents.deletion_confirm/1`), set apart by a rule in the error colour at its
left: what is lost, the field asked to confirm where there is one (the slug, or for the
account its email), then the question, Delete Acme?, with its red button, Yes, delete,
disabled until the field matches, and Cancel beside it (`<.inline_confirm>`). The field
takes the focus, or Cancel where there is none to type (a node's); the line's own button
then folds it (`aria-expanded`), and Cancel and Escape, a patch back to the page, give
that button the focus back. Where the act is not there, the line says why in place of the
button: the instance's own organisation, the organisation's only workspace; where
something stops it for now, the button is disabled and the page says what under the line
(the organisations a person is the only owner of). A reader who may not delete the scope
sees no danger zone, and the act's path sends them to General and says why.

Deleting any workspace from Workspaces is confirmed the same way in its row
(`/:org/settings/workspaces/:workspace_id/delete`): the row shows the confirmation in
place of its cells, its slug typed to enable Yes, delete, and Cancel gives the row back.
Every other act on a row of a list (revoke, remove, suspend, a deletion) is
confirmed on its row too, each at a path of its own (No modals, above).
The old paths, `/:org/members/…` and `/:org/:workspace/settings/retention`, send on to
the new ones
(`ApiaryWeb.MovedController`).

An organisation's own path, `/:org`, is its overview (`ApiaryWeb.OrganisationLive`): the
workspaces the person reaches, what each is doing, and the organisation's people; its
header's actions are the edition's (the `:organisation_heading` slot), such as a way to add
a workspace. The breadcrumb's organisation leads there; `/` still sends a person to the workspace they
opened last.

### Secrets and variables

A workspace's Secrets and variables (`ApiaryWeb.SecretLive.Index`, with `security`, for a
reader of `secret.read`) is one section of two tabs, under its `<h1>` and its sentence:
**Secrets**, `/settings/secrets`, and **Variables**, `/settings/variables`
(`PageComponents.page_tabs/1`, `place="section"`, `#secrets-tabs-secrets` and
`#secrets-tabs-variables`), each a link with its count, the current one
`aria-current="page"`, not an ARIA tablist; the bar is a navigation named "Secrets and
variables", wraps and does not stick. Each tab's panel holds, in order, the line that a
run receives only its security policy, who changes them, its New (New secret, New
variable) beside its search, Filter and Sort, and its list: nothing in the header changes
with the tab. Each list is on the list pattern (Lists, below), its search, its Filter
menu, Sort and its tokens in the URL (`ApiaryWeb.SecretLive.Query`): a secret found by its
name or a value ID and filtered by one value or several; a variable by its name or its
value, and filtered by its lock and by whether a repository sets it too; both ordered by
name or the latest change.

- **Where you are.** The breadcrumb ends `Workspace settings / Secrets and variables` on
  both tabs (a tab is not a segment), the section the page (`aria-current="page"`), and
  the second column marks the section as the page on both tabs too. The browser's title
  names the tab: `Secrets and variables · Workspace settings · Main · Acme`,
  `Variables · Secrets and variables · Workspace settings · Main · Acme`.
- **One status line** (`#secrets-and-variables-status`, `role="status"`), there from the
  start and outside both tabs' parts, says out of sight the tab a switch led to and its
  count ("Variables, 7"), and under the filters what a search left ("1 secret matches").
  The focus stays on the tab that was activated.
- **What a run receives.** Each tab, and each of its pages, says once near its top "A
  run receives only its security policy." (`ApiaryWeb.PageComponents.not_on_runs/1`),
  and no line of the section says a run is given what it holds.
- **A secret** is one row: its name in mono, its note beside it, how many values it
  holds, and who changed it and when (`ApiaryWeb.People`). A secret of several values,
  or of one named value, has a line under it for each, its value ID in mono, with who
  changed that value and when, and the value's own acts. **No value is ever rendered**:
  the value is a textarea whose content is always empty, written and sent once; the form
  the context hands back after a refused save holds none, so a refusal shows the error
  under an empty field, and a save goes back to the list, so the field is gone. No secret
  form sends a change event, so a value travels only when it is submitted. A parameter
  named `value` is `[FILTERED]` in the logs, a LiveView event's included
  (`:filter_parameters`).
- **A variable** is one row: its name, its value in mono (plain configuration, shown
  whole on hover), its lock (the faint lock and Locked; a value set aside by a lock above
  the workspace says so), and the repositories that have a value of their own, or whose
  value the lock sets aside, from their resolution
  (`Apiary.Variables.repository_overrides/1`), a link to the page that lists them. No
  page sets a repository's own value: the context keeps one
  (`Apiary.Variables.create_variable/3` with a target), and the demo makes a few. Locked
  means a repository's own value of the name is set aside, and nothing more. A name on
  Forager's deny list other than `QORY_…`, which the context refuses, is saved with a
  warning on New variable's page ("NAME is on Forager's deny list.", which describes
  the name's field while it shows) and "On Forager's deny list" on its row.
- **New secret** asks for its name, then **Values**, native radios in a fieldset with that
  legend: "One value" (to start), its one Value, with no value ID; or "Several values,
  each with a value ID", a Value ID and a Value for each, two to start, each row a group
  named for whoever hears it ("Value 3"), the rows past the first two with Remove (named
  "Remove value 3" for whoever hears it), and "Add another value" under them, off at 32
  with "A secret holds at most 32 values." beside it. The group not chosen is hidden and
  its fields are off, as the server renders it and as the `SecretValues` hook keeps it:
  the choice and the rows work in the browser alone, nothing is sent before Save, and
  Save sends the values of the choice taken, not the other's, and stores the secret with
  all its values at once (`Apiary.Secrets.create_secret/2`). A render the server sends
  for anything but a save (a count in the sidebar) keeps the choice, the rows and what
  is written in them, which the hook holds in the browser for that moment alone; the
  name and the note are not kept, as on every form. A refused save shows the rows that
  were sent, each with its value ID and its errors under its own fields (a value ID
  twice, one not lowercase or not text, a row left empty), and every value empty, to
  write again, as one value's is. More than 32 values are refused before any is read,
  once, under the rows, the Values choice described by it, and the rows start again.
- **The forms are pages** of the section (A form is a page, above), each at a path of its
  own: for secrets New secret (`/settings/secrets/new`), Edit name and note (`/:id/edit`,
  "Edit the name and note of FORGE_TOKEN", its values left as they are), Add value
  (`/:id/add-value`), Change value (`/:id/change-value` for a secret's one value without
  a value ID, `/:id/values/:value_id/change` for a named one) and Rename value
  (`…/values/:value_id/rename`); for variables New variable (`/settings/variables/new`) and
  Change value (`/:id/change`). They show no tabs. The breadcrumb ends `Secrets and
  variables / New secret` (and `Secrets and variables / New variable`), the section
  leading back to the tab the page was opened from, with its query.
- **The targets of a variable** are a page of the section too, to read
  (`/settings/variables/:id/targets`, "Repositories that set NODE_ENV"): each with its own
  value or its value set aside by the lock, found by their path past ten, and Back to the
  variables at its foot. Its row's count of them in the list leads there.
- **Deletions confirm in place**, on the row they act on (No modals, above): Delete
  secret (`/:id/delete`), Delete value (`…/values/:value_id/delete`) and Delete variable
  (`/:id/delete`) turn the row into "Delete FORGE_TOKEN?", what is lost, Yes, delete and
  Cancel. **Lock and Unlock act at once** from the row's menu, and the flash says what the
  lock did to the targets that set their own; their paths, `/:id/lock` and `/:id/unlock`,
  which must not act as they open, ask on the row first. A confirmation the context
  refuses (a lock, an unlock or a deletion that would raise a target's variables over
  their limits, a secret something uses, a secret's last value) stays open and says why
  under its question, as an alert, the focus left on its button; a Lock or Unlock from
  the menu that is refused says why in the flash. A secret is named by its public id, a
  variable by its row's. A path the reader may not open, or of a secret or variable
  the workspace does not have, sends them back to the tab and says why.
- **Who.** Every member reads both tabs; owners and admins change them (`secret.write`,
  `variable.edit`). A reader who may not sees no New, no ⋯ menu, and once, in the tab's
  panel, "Only owners and admins change this."; a form's page sends them back to the tab
  with the same words.

## Lists

A page that lists things reads top down, and every level of it has a look of its own: a
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
  a run that succeeded say nothing (a screen reader hears the word); a suspended
  member, a revoked key say so in words (`<.state_word>`), with a dot and the
  text colour when the state needs someone. A pill is for a state of at most two words
  that needs someone, and never on every row.
- **A row's acts.** The one act its state asks for is a text action (`<.button
  variant="link">`); the rest are in its ⋯ menu
  (`<.row_menu>` with `<.menu_item>`s, a heading and dividers between groups), which
  floats in the top layer so the table's scroll region never clips it. A choice of one,
  such as a person's level, is a set of `menuitemradio` items with what each means. A
  destructive item asks on its row, at a path of its own (No modals, above); red is for
  that confirmation's button only. No bordered button on every row. Network access is
  the exception: Allow and Deny are icons and the row has no ⋯ menu (Lists, A
  destination).
- **Columns grow with the table**, not the screen: `from="sm" | "md" | "lg"` shows a
  column from 600, 1000 or 1300 px of the table's own width (a container query), so a
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

The policy's lists of rules (`PolicyComponents.rule_list/1`, on the workspace's Rules tab
and on a target's Policy tab) are on the same pattern, their query read and written by
`ApiaryWeb.PolicyLive.RuleList`, pure over the rows the page holds: views All, Allowed,
Denied and Locked, each counted under the search and the other filters, the Rules tab's
count the All view's with nothing narrowed; "Find a host" with the qualifiers `seen:`, `paths:`, `by:` and
`source:` as tokens, sent as the reader types and read whole on Enter; one Filter menu
whose sections come from the rows' sources and people (an edition that adds rules of
another holder gives them a source, and the menu, the qualifier and the order take it);
Sort (the list's own order, Host, Most used, Recently added); pages of 50; and `?rule=`,
which Network access links with, landing on the page that holds the rule and marking it.
A target's Policy tab shows each rule's Source; its own rules come first and have the ⋯
menu's acts, the workspace's are read there and lead to the workspace's page. A rule of
the level above the workspace has that level's tile in its Source, which says whose it is;
the faint lock is a locked rule of the workspace's alone, what the Locked view counts.
The mode is a card above the tabs, the same on the workspace's Policy page, on each of
its tabs, and on a target's Policy tab, above its views (`PolicyComponents.mode_card/1`);
a version and its export, which state their own mode, have none. It states the mode in
force: a honey tile with the mode's icon (a lock where a level above requires enforce),
"Mode: Enforce" as its heading, whose it is as a badge (Workspace default; Follows the
workspace, by its name, or Its own; Required by the level), one sentence of what the mode
does and who follows it, and on the workspace's the record of the last 14 days with its
link. A member sees the card with no Change mode and the line that says who may.

The policy pages confirm in place, never over the page:

- **A mode** is chosen, then confirmed, never switched at once. Change mode opens the
  choices in the card (`?confirm=enforce` lands with them open and Enforce picked): one
  option card per mode (Follow the workspace first on a target), each a native radio with
  what it does, the mode now marked Current. A pick only selects. A pick that is not the
  mode now asks under the options: the question, what it does and in whose runs (or that
  nothing changes today, and what changes from now on; on a workspace nobody has changed
  yet, that it is the workspace's first change), for enforce what the last 14 days let
  through with no rule, each with its Allow; then one primary button that names the pick
  and Cancel. Escape, with the focus in the choices, cancels (the `PolicyPage` hook);
  saving or cancelling gives the focus back to Change mode, and the save is said in the
  page's status region. The choices stay open on another tab.
- **A rule's row** asks for its own acts where they cost something: a Lock that would put
  a target's own rule out of force, and the Remove of a locked rule or of one a target
  overrides. The row becomes its `inline_confirm/1` (`rule_list/1`'s `confirming`): the
  question, what follows, Yes, lock or Yes, remove, and Cancel, which gives the focus back
  to the row's ⋯. A plain Remove, a Lock that holds nothing back and Unlock act at once
  and say so.
- **The keys**: `?` shows and hides the list of the page's keys, a panel at the top of
  the page (`#policy-keys`), not an overlay; Escape and its Close hide it.

**The export** (`…/policy/versions/:n/export`, and a target's
`…/-/policy/versions/:n/export`) is a page, not a dialog: the top bar's breadcrumb ends
with Version n and Export and is the one way back, with no trail of the page's own; the
title "Export for a node without a server" and what is exported (an h2 under a target's
own title), the policy file with Download and Copy, the command for the
node and the Forager file's egress section, each with Copy, the notes, and Done back to the
version. Only the version in force is exported; another version's path sends on to it.

- **Views** are the runs list's All, Alive, Ended badly and With denials, and Network
  access's decisions, each counted under every other filter; All is current when no
  other is. An Ended run counts with the runs that ended well, never under Ended badly,
  and the Filter menu's State section lists Ended with them. A view's own filter is not
  repeated as a token. The number that matches is a line over the list, only when the
  list is narrowed ("87 runs match"), in the list's status region (`role="status"`,
  `.q-status`), which is always rendered, empty and taking no place otherwise, so a
  screen reader hears what a view, a filter or a search left; an empty list says its
  empty state's title there too.
- **The search is a query** (`<.list_search live={false}>`, sent on Enter): qualifiers
  (`repo:`, `state:`, `runtime:`, `host:`, `node:`, `started:>2026-09-01`, `denied:yes`;
  `decision:`, `tools:`, `seen:` on Network access) become the URL's parameters and show
  as tokens, and the other words are the free text, `q`, matched as text without regard to
  case (a run's id, title or target; a destination's host or path). A word it cannot read is said in a notice, never dropped in silence. On Network
  access the field suggests the hosts in the list as one types (a combobox, at most 8,
  from the host filter's query, narrowed as the list is); choosing one adds `host:`.
- **The Filter menu has sections** (`<.filter_menu>` with `section`s): too many values for
  a menu, each section searches its values on the server over every value there is,
  fifty shown and more on asking, each counted under the other filters
  (`RunComponents.filter_options/1`).
- **The rail** (`<.target_rail>`, from 1280 px) holds the targets with their counts under
  every filter but the target, in the list's unit: runs on the runs list ("Most runs"),
  destinations on Network access ("Most destinations"), as its views and its Filter
  menu's Target section count them. A search on the server, every target, the pinned ones
  first under Pinned (`counts.pins`), then the busiest twenty and "n more", its own
  headings under an `<h2>` for a screen reader so the outline never skips a level.
  Choosing one sets the target; below 1280 px the Filter menu's Target section does it,
  never both.
- **A run is one line** (`<.runs_table>`): its title, else its id, the only strong text; its
  target after it until the table is 1000 px wide, then in a column; its state a dot
  (`<.run_mark>`) with its word where the state needs a look, and its denials red only
  when there are any. Ended shows its word, a grey dot as Closed's. A run with no session
  says "no session" in the Runtime column, muted as the column is, and "n/a" as its Host.
  What the run says it is about is a muted line under them, only when it names a kind or a
  subject: the kind, then up to two subjects, each its type and ref
  as given ("pull request #412"), then "+N more", as text and never a link, since the
  title's link covers the row. Below 640 px it names one subject, so the count stays in
  sight; the whole line is its tooltip.
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
  hover, on its own focus and while it says Copied, always on a touch screen. Where the
  rule in force is the one the reason names, its name links to it; where the level above
  decides the row, its "Main · denied" (or allowed) links to that rule; a row a rule was
  just added for ends its after line with Show the rule. A locked rule, the wall, a deny
  of the level above, and an allow only the level above can grant for a reader who may
  not change it there are a faint lock whose hint says why (who locked it and when,
  where known); a locked rule's lock opens its refusal in place, with the way to the
  rule. Where only the level above the workspace allows
  a host, the row's reason says so in words, and Allow opens a panel that says an allow
  here would not be in force and leads to that level's policy with the host, for a reader
  who may change it there, and with the way back to this page (`back`,
  `c:ApiaryWeb.Edition.above_policy_link/1`); never a navigation on the click alone. A
  row opened by its chevron lists the runs that reached it as lines under it, a dot for each state, no box. The
  default order, Denied first, puts the destinations whose last attempt was denied
  first, the most denied attempts first and then the most recently seen, as To
  review weighs them; the rest by when they were first seen, so they hold still.
- **A row's rule is asked for in place** (`RunComponents.rule_panel/1`), never in a
  popover, a dialog or a sheet: Allow, Deny and a locked rule's lock open
  a row of the table's own right under the row (`#<row>-panel`), in the page's flow, the
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
  card, of the run chosen (`?run=`; the first row until the reader chooses one), with the
  last lines of its log as plain text. The `RunList` hook tells the page the width, turns
  a row's click into a choice there, and moves it with ↑ and ↓; Enter or a second click
  opens the run. Below 1920 px a row is a link to its page.
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
- **The overview's summary** counts the chart's fourteen UTC days, and each number leads
  to its list over the same days (`?from=` the first of them; the denied attempts to
  Network access, whose Denied view counts the destinations the summary names). **To
  review** weighs the same fourteen days but lists only what is still denied, no rule
  having allowed it since, and its "and n more" says so.
- **The Policy page's** fact on the mode card and the enforce preview read fourteen days,
  so "See them" lands on the same numbers; a rule's use is its last fourteen days.
- **The targets index** counts runs, the share that ended well and denied attempts over
  the same fourteen days, each column saying so; a **target's page** counts its denied
  destinations as Network access does (host, port and path), so its card and its Network
  access tab agree.

Elsewhere a window is said where it is used: the runs list has none unless set, a lost
run is listed for seven days, a key is idle after thirty.

## The overviews

The workspace overview (`ApiaryWeb.WorkspaceLive.Overview`, `OverviewComponents`) answers
what needs the reader, then what their agents did, and never grows with the data:

- **The summary**: alive now, runs, runs that ended badly and denied attempts over
  fourteen days, each a link to the list it counts over the same days.
- **To review**: one line an item, on columns the list holds (each row a subgrid,
  so they line up whatever an act says), its mark, its subject, where it is, the reason
  in a few words (the longer sentence on hover), when, and the one text act that settles
  it; five shown and "and n more". Its Allow is Network access's: the same panel, in
  place inside the item under its subject (`#<item>-panel`), never an overlay, the target
  chosen when only one reached the host, and the focus on the next item's act once the
  rule is written. Where the level above the workspace denies the host, or allows only its
  own hosts, no allow here would be in force, so the item offers the way to that level's
  page to one who may change it there, and a lock with the reason to the rest. A resolved
  item stays, struck, until the next
  navigation; one that arrives is announced (`#overview-announcer`), never inserted above
  what is read. A lost run's Close asks on its own line: the row becomes its
  `inline_confirm/1` ("Close nightly-mirror?", what a close does, Yes, close and Cancel),
  never a dialog; Cancel or Escape gives the row back with the focus on its Close.
- **Activity**: runs and denied attempts per day on one day axis, drawn for the width the
  `DaysChart` hook measured, with its table twin a text action away.
- **Active targets**: the eight with the most runs, each with its last run (a dot, and a
  word only when it is running or ended badly), a sparkline of its days and its denials.
- **Guard**: a few lines of key and value, each with a muted detail and one link that
  says what it does: the policy's mode and version, the targets with rules of their own
  (Review), retention (Change, to Workspace settings › Runs).
- A workspace no run has reached is one box: the steps from a node to the first run, and a
  panel beside them. Step 2 is "Connect it" ("Run one command on the machine, or generate
  a key for a CI or another system."). While it is current, it names the newest node or
  pool with no active key, its name linking to that one's Access key tab. At step 1 the
  panel explains "Two ways to connect a machine", Generate a key in the browser's line ending "… this
  page shows the key's secret once, and you copy it into that system."; at step 2 it asks
  an owner or admin "How do you want to connect build-01?", with the two ways as rows,
  Connect with a command and Generate a key in the browser, a pool's Generate a key in
  the browser first, the buttons Get the command and Generate a key. Get the
  command there makes the command in place, as on the tab: the panel shows the real
  command with Copy, "It works once, until 14:32. This is the only time it is shown." and
  "Waiting for build-01 to run it.", with the notice when the server's address is a
  loopback one. Generate a key opens the node's Generate a key page. A member reads who
  connects it, and Go to nodes. At step 3 the panel reads "Listening for the first run.
  build-01 verified 2 min ago." alone. No placeholder command shows anywhere.

An organisation's overview lists its workspaces one line each, six at most and a link to
all, with its people and details as lines beside them; Details has no link to the
settings, which the sidebar's foot, Organisation settings, leads to on the same page.

## Targets

A workspace's targets have an index and a page each, GitHub's organisation repositories
and repository page in the target's words (`ApiaryWeb.TargetLive.Index`, `…Show`; the
reads are `Apiary.Targets`'s, the looks `ApiaryWeb.TargetComponents`'s).

- **The notation.** A target is its path in mono (`<.target_name>`); its system goes
  before it, faint, only where the same path is in another system of the workspace
  (`Apiary.Runs.shared_paths/2`), and always on its own header and crumb. A run's state
  is a dot and, when the run needs a look, its word (`<.state_mark>`), never a pill.
- **The index** (`/:org/:workspace/targets`, width `list`) is narrowed the way every list
  is (Lists, above): views with the workspace's counts (All, Active this week, Never ran),
  one search, one Filter menu (System, Activity, Policy, Pinned) and Sort (Last run, Name,
  Most runs in 14 days, Most denials in 14 days), with the filters in force as tokens under the
  bar. A filter is a qualifier of the search (`forge:` in the software domain, `mode:`,
  `activity:`, `is:pinned`; `ApiaryWeb.TargetLive.Query`): the menu writes it, and one
  the reader types becomes a token on Enter, never half typed. All of it is the URL; a
  value the page does not know is left out. A row is one line on the row spec: the
  reader's ★, the path the title, the last run as a dot and a time (its word when it is
  running or went badly), a 14-day sparkline of runs with their number, the share that
  ended well (lifted to the text colour below 80 %; red is for denials only), the denied
  attempts of the same fourteen days in red when there are any, and the policy mode only where the target sets its own. Pages of 50.
  Below 600 px of table the last run is a line under the path. It reads in one query
  bounded by the fourteen days, and re-reads at most once a second as runs land, changing
  the rows it holds in place.
- **A target's page** is `/:org/:workspace/targets/:system/*path`, its tabs after a `-`
  segment, GitLab's way (`target_path/4`): Overview at the bare path, then `…/-/runs`,
  `…/-/network` (once `…/-/connections`, which the page sends on with its query, moved
  permanently) and, with `security`, `…/-/policy` with the policy's own paths after it
  (`/history`, `/document`, `/versions/:n`, `/export`). A path with a segment that
  would be misread (empty, `-`, `.`, `..`) is one segment, its slashes escaped. A target
  the workspace does not have, and a tab the page does not know, are not found. The header
  names the target as it is addressed (its path, its system before it only where two
  targets share the path) with the reader's pin, one muted line (its runs since it was first
  seen, its last run, and its mode only where it sets its own) and Open on the system when
  the system is a host name; the breadcrumb ends with the section, a link to the index,
  and the target, then on a version of its policy `Version 3` and on its export
  `Export`, as on the workspace's Policy.
  - **Overview**: two cards, each one list, the few with a link to the many (its last
    runs; the destinations it was denied in 14 days, each with a faint barred circle,
    never red), beside a plain About column (the
    system and path, when it was first seen and by which run, the same path elsewhere,
    its runs a day, its machines and runtimes). A run that lands is counted, never
    inserted, and comes in when asked.
  - Its runs and its Network access are the workspace's lists narrowed to it
    (`/runs?target=acme/shop`, `/network?target=acme/shop`); the old `…/-/runs`,
    `…/-/network` and `…/-/connections` send on there with their query.
  - **Policy**: the target's view of the policy (`ApiaryWeb.PolicyLive.Target`): its
    mode card (Follow the workspace, by its name, Observe or Enforce, and whose the mode
    is), the rules in force for it on the list pattern with their Source, and
    its history and document as views under the page's tabs. Its old paths, `/policy/targets/:target_id/…`, send on here
    (`ApiaryWeb.TargetMovedController`).

  A tab is its own mount; a tab another page's module answers is handed the page's
  parameters, events and messages while it is open.
- **Pins** are the person's own (`target_pins`): the ★ of a row and of the header, and the
  sidebar's Pinned group.

## Nodes

A workspace's nodes and node pools are where its runs run (`ApiaryWeb.NodeLive.Index`,
`…Show`; the reads and changes are `Apiary.Nodes`'s). A **node** is one permanent machine,
which runs one instance at a time; a **node pool** is a fleet of short-lived instances,
which run up to its instance limit, or any number without one. The kind is chosen when one
is made and never changes. A node is named in a path by its public id, `nd_…` for a node
and `np_…` for a pool. Nodes is an entry of the workspace's sidebar, in Record after
Targets (`#nav-nodes`, for a reader of `node.read`); the list, a node's page and the New
node forms pass `nav={:nodes}`, so it is the current entry on all of them.

- **A node's state** is never Online or Offline (`ApiaryWeb.NodeComponents.node_state/1`).
  An instance is **running** while it has a run alive by the lost-run check's rule
  (`Apiary.Runs.Liveness.alive/2`): running means "not yet lost". A Node says
  "Running"; a pool says "3 of 10 running", or "3 running" without a limit; one that runs
  nothing says "Last seen" and a time that ticks, or "Never seen" until an instance of it
  reports. Once a pool's instances are pruned, a day after they were last seen, "Last
  seen" is when one of its keys, revoked ones too, was last used; "Never seen" is for a
  node with no instance and no key ever used.
- **The list** (`/:org/:workspace/nodes`, width `list`) is on the list pattern (Lists,
  above): one line a node, its name the title with its public id beside it in `q-side`,
  its kind in words only for a pool ("Pool"; a node, the usual kind, says nothing), its
  state, and from `md` the Forager version it last reported. Under a pool's line, its
  running instances as indented lines (name, id in `q-side`, "Running since", its run),
  ten at most, then "and 12 more", which leads to the pool's page; an instance shows only
  while it runs, and a Node has none, its one instance being its line. The views are
  All, Running and Not running (`?view=running`, `?view=idle`), counted under the search
  and the kind; one search, `?q=`, words of a name or an id, and the Filter menu's Kind
  (`?kind=node`, `?kind=pool`), each a token under the bar; Sort by Name or Last seen
  (`?sort=seen`: running first, never seen last). Owners and admins have **New node**
  and **New node pool**, side by side and alike, in the header; with no node yet, the
  empty state offers both, and tells a member that an owner or admin adds nodes.
- **New node and New node pool** are pages of the Nodes section at paths of their own,
  `/nodes/new` and `/nodes/new-pool`, on the pattern of a form page (Settings, A form is a
  page, above) in the `read` width: the workspace's sidebar, the breadcrumb ending
  `Nodes / New node` (Nodes a link back to the list), the page's heading
  (`PageComponents.page_form/1`, no Back link) and one sentence of what the kind is, with
  "You can't change the kind later"; then the form, a name (it takes the focus), and for a
  pool its instance limit (a whole number up to 10,000, or empty for none), and its foot,
  Add node or Add node pool with Cancel back to the list (`page_form_foot/1`). A refused
  save stays on the page, the error under its field; adding one opens its page on
  Access key with a flash, where its machine gets its key.
- **A node's page** (`/nodes/:node_id`) has a header (the node's name and public id, then
  one muted line: its kind, its state and who made it when) and its tabs, the operational
  side first and Settings last, set apart at the bar's right end
  (`NodeComponents.node_tabs/1`, on `PageComponents.page_tabs/1`). Overview and Settings
  are patches of the one LiveView; Access key, between them, is a LiveView of its own
  (`/nodes/:node_id/access-key`, `ApiaryWeb.NodeLive.AccessKey`). **Overview**: a Node's
  instance (running since when,
  its run and Forager version, or when it was last seen) or a pool's running instances on the
  list pattern with "3 of 10 running", the starts refused at the instance limit, the
  instances past the bound of 256 new ones a day, the sentence that an instance is what
  Forager, run with the node's key, reports itself as, and its recent runs (`runs.node_id`,
  for a reader of the record) with the way to all of them on the runs list (`?node=`),
  each saying so while nothing has reported, then About (kind, id, instance limit, who
  made it), which leads to Settings; and **Settings** (`/nodes/:node_id/settings`), its few
  sections listed in the page, never as a second column (Settings, A node's): General,
  whose danger zone's Delete node… (Delete node pool… for a pool) expands its
  confirmation in place (Settings, The danger zone) at `/nodes/:node_id/settings/delete`:
  what is lost, then Delete build-01? with Yes, delete and Cancel, no field to type, Cancel
  taking the focus.
  Deleting a node takes it out of the list, frees its name and keeps its runs in the
  record. A node the workspace does not have, or a deleted one, is not found.
- **Access key**, a node's tab. While the node holds no active key, owners and admins read
  "How do you want to connect build-01?", "build-01 connects to Qory with a key. Choose
  one of two ways to give it one." (a pool's: "spot-runners connects to Qory with a key;
  its instances share one. Choose one of two ways to give it one."), and
  two options of equal weight, side by side from `md`, stacked below it, of one height
  (`items-stretch`), each its icon and title, "Choose it when …" in the body colour, what
  happens in two muted sentences, then the same four facts in the same rows (a `dl` of two
  columns, the labels faint: Key made, Secret, By hand, Needs), a waiting command where
  it is the command's, and one button at the foot (`mt-auto`), so the buttons line up.
  No steps, no code, no variable and no Copy. **Connect with a command**: "Choose it when
  you can open a terminal on build-01: a laptop, or a server of your own.", "You get one
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
  address", Needs "This page open over HTTPS", then Generate a key. A node lists the
  command first, its button primary; a pool lists Generate a key in the browser first. A
  member reads, under "Connect build-01", "build-01 has no key yet, so it isn't connected
  to Qory. An owner or admin connects it." A command not yet run shows
  in the command's option, above its button, or its row under Add a key: "A command is waiting to be run
  on build-01.", "dana@example.com got it at 14:17. It works once, until 14:32. It was
  shown once: if it's lost, cancel it and get a new one." and Cancel the command…,
  confirmed in place ("Cancel the command from 14:17?", Yes, cancel it and Keep it); its
  button becomes Get a new command. There is no list of codes. With keys, the tab lists
  them under Keys, with a count, one card each, headed by its label and Active or Revoked:
  Key ID, `ak_…` with Copy, since the ID can always be seen again, Added ("Connected with
  a command by dana@example.com, …" or "Generated in a browser by …"), Secret (where the
  key's secret is), Last used ("Not yet" while unused), Fingerprint and Stored secrets,
  and an active key's **Forager file**, for everyone who reads the node, and Revoke…,
  confirmed in place. A key whose record doesn't match its integrity code says so on its
  card: "… It can't be used." Under the keys, Add a key says how to move to a new key, add
  it either way and then revoke the old one, and offers the two ways as compact rows, in
  the same order, each its title and its "Choose it when …" line, with its button. At two keys, the most a node or a pool holds, it has no
  buttons, only "build-01 holds two keys, the most a node can. Revoke the one it no longer
  uses to add another." A member sees the keys and none of the actions. At the foot, once
  the node holds an active key, **Configure a machine** (`#node-configure`), for everyone,
  at the limit too, at most 46rem wide: "A machine connected with the command needs
  nothing more: qory saved all of this on it. Don't set these again there; qory refuses a
  key ID or a public key set twice." and "With a generated key, set these where the
  machine runs qory.", then four numbered steps (`q-steps`): 1 "Point qory at Qory Apiary." ("In the Forager
  file. It is required: without it, qory ignores the three variables below.",
  `forager.yaml` with Copy lines), 2 "Set Qory Apiary's public key." ("QORY_APIARY_PUBLIC_KEY,
  a plain setting. The same for every machine connected to this Qory Apiary.", the value
  with Copy), 3 "Set the key's ID." (with one active key, "QORY_ACCESS_KEY_ID, a plain
  setting." and its ID with Copy; with two, "QORY_ACCESS_KEY_ID, a plain setting: the ID
  of the key the machine uses, on its card above."), 4 "Keep the key's secret in a secret
  store." ("QORY_ACCESS_KEY_SECRET. It was shown once, when the key was generated, and is
  never shown here. If it is lost, generate a new key and revoke the old one.", text
  alone, never a value or a Copy).
- **Connect build-01 with a command** (`/nodes/:node_id/access-key/new-code`, owners and
  admins; its crumb is Command) is where Get the command leads. The click makes the
  enrolment code at once, with defaults: Stored secrets Not allowed and no label hint, so
  qory names the key after the machine's host name; there is no form. The page shows the
  whole command, `qory access-key enrol https://apiary.example.com` and the code, wrapped,
  with one Copy command. For a node or pool that has or had a key, the command carries
  `--replace` (`qory access-key enrol --replace https://apiary.example.com` and the code),
  shown and copied alike, with the line "It moves build-01 to a new key. The old key keeps
  working until you revoke it on the Access key tab." under it while a key is active, or
  "It moves build-01 to a new key." alone once every key is revoked; a code waiting
  unused does not count. Then "It works once, until 14:32, 15 minutes from when you got
  it. This is the only time it is shown." and "Waiting for build-01 to run it. This page
  shows when it is connected." The code is never shown on its own, and the page never
  names it. When the machine runs the command, the page turns, live, to "build-01 is
  connected. Its key arrived at 14:20 and is active.", with the Key and its Fingerprint,
  and "qory printed a fingerprint on build-01 when it ran the command. If it isn't this
  one, revoke the key on the Access key tab." When the server's own address
  (`ApiaryWeb.Endpoint.url/0`, from `PUBLIC_URL`) is a loopback one, such as
  `http://localhost:4100`, a notice says "Machines can't reach this address. … Set
  PUBLIC_URL to the address machines use, and the command will carry it."
- **Generate a key for build-01** (`/nodes/:node_id/access-key/generate`, owners and
  admins; at the key limit it goes back to the tab with "build-01 holds two keys already.
  Revoke one before you add another.") is a form page: "This browser makes a key for
  build-01. You see its secret once, to copy into your CI's secret store, or the settings
  of the system that runs it; Qory Apiary receives only the public half. The key's ID stays on
  the Access key tab." (a pool's ends its first part "… or the settings of whatever runs
  the instances"), then one field, Name of the key, filled in with the node's name (then
  `-2` when a key has that name), its hint "Shown on the Access key tab, so you can tell
  its keys apart.", and Generate key ("Generating") with Cancel. There is no Stored
  secrets choice: every new key, either way, is Not allowed. The browser makes the Ed25519
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
- **Key for build-01** (`/nodes/:node_id/access-key/keys/:key_id/generated`) is what
  Generate key leads to, with no flash: "Do these where build-01 runs. Only the secret
  can't be seen again.", the notice "**The secret is shown once.** …", then four numbered
  steps, each value with Copy. 1 "Store the secret." ("In the secret store of the system
  that runs build-01, such as your CI's.", `QORY_ACCESS_KEY_SECRET`, tagged "secret ·
  shown once"), 2 "Set the key's ID." ("As a plain setting. It stays on the Access key
  tab.", `QORY_ACCESS_KEY_ID`), 3 "Set Qory Apiary's public key." ("As a plain setting.
  The same for every machine connected to this Qory Apiary. It stays on the Access key
  tab.", `QORY_APIARY_PUBLIC_KEY`, the pin as JSON), 4 "Point qory at Qory Apiary." ("In
  the Forager file. It is required: without it, qory ignores the three variables.", the
  two lines `server:` and `url: https://apiary.example.com` with Copy
  lines). The server's address and public key are the instance's own, the same for every
  organisation, workspace and node; the key comes from `APIARY_SIGNING_SECRET`. Then Done
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
- **Forager file for build-01** (`/nodes/:node_id/access-key/keys/:key_id/forager-file`, an
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
  revoke this one."), 2 "Set the key's ID." ("As a plain setting.",
  `QORY_ACCESS_KEY_ID=…` with Copy variable), 3 "Set Qory Apiary's public key." ("As a
  plain setting.", `QORY_APIARY_PUBLIC_KEY=…` with Copy variable, then "The same for every
  machine connected to this Qory Apiary."), 4 "Point qory at Qory Apiary." (`server:` / `url:` with Copy lines). Done goes back to the
  tab, the focus on the link.
- **Clear instance** (owners and admins, `node.clear_instance`) is a text action on a
  Node's running instance and an item of each row's ⋯ menu on a pool's; at
  `/nodes/:node_id/instances/:instance/clear` (the instance's id) that line, or that row in
  place of its cells, is the confirmation, no dialog (`<.inline_confirm>`): "Clear
  build-01? Clear this instance if it stopped without saying so. Another instance can then
  start at once." with Yes, clear and Cancel; an instance that does not run now confirms at
  the top of the instances. Its open runs are marked lost, which is not final: a heartbeat brings a run back.
- **Live**: the list and the page read again on `{:nodes_touched, workspace_id}`
  (`Apiary.Nodes.topic/1`) and on a `{:run_changed, run}` of a run on a node, at most
  every 250 ms, and every 15 seconds, since an instance stops running without an event.
- **Where a run ran**: the run page's details say Node (linked, or "(deleted)") and
  Instance (its name and id) beside Key, and so does the runs list's preview, each only
  when the run names one; the runs list takes `node:` (a public id, or the name of a node
  in use) and has a Node column from 1300 px (`q-rl-c5`) where the workspace has nodes.
- **Members** read the list and every tab, without New node, New node pool, Clear
  instance or the danger zone; Settings shows its fields disabled under one line that
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
hides its own parts on phones in that block.

## Components

A page composes components; it does not write its own button, input, table, modal or
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
  tabs (a target's, a node's, a run's), links, Settings, where the thing has it, last and
  set apart at the bar's right end, and a settings section's (Secrets | Variables,
  `place="section"`, in the flow, wrapping); `settings_page/1`, a page of a level's
  settings, whose sections the frame lists (Two levels, under The shell); `page_form/1` with
  `page_form_foot/1`, a form as a page of its own, its title, one line and the form, with
  no Back link in its header, since Cancel at its foot and the breadcrumb lead back (a
  link at a page's foot that names where it leads, such as Back to the variables, stays
  where a page has one); and
  `not_on_runs/1`, the one plain line a page over data no run receives says, in the
  page's own sentence (`inner_block`, required): it has no words of its own.
- **`<.button>`** has the variants `primary`, `default`, `ghost`, `danger`,
  `danger-ghost` and `link`, and renders a link styled as a button when given `navigate`,
  `patch` or `href`, unless it is `disabled`: a disabled one is a `<button disabled>`
  whatever its path, never a link that still focuses and patches to itself (the pager's
  Newer on its first page). `primary` marks the one main action of a screen. `loading_text` is
  the gerund ("Saving") the button shows, with a spinner and `aria-busy`, while its form
  submits; the button keeps its width.
- **`<.input>`** is every field; with `prefix` a text input shows, in mono before the
  value and as one field, what the value completes: the path of the organisation before
  a workspace's slug. A caller's `aria-describedby` is merged with the field's own (its
  hint, its errors), never replaced by it.
- **Forms** are `novalidate`, every one, plain `<form>` and `<.form>` alike: the browser
  neither checks a field nor shows its own bubble, and the server answers a field that is
  wrong with an error under it (`<.input>`'s, tied to it by `aria-describedby`), in the
  page's words. A field keeps what helps a person, `required`, `type="email"`, `inputmode`,
  `autocomplete`, for assistive technology and a phone's keyboard; so a check the browser
  made is the server's too. A whole number is a text field with `inputmode="numeric"`,
  not `type="number"`, whose value the browser empties when it is not a number.
  `test/apiary_web/novalidate_test.exs` fails for a form without the attribute.
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
  acts, unless the act names its own (`confirm_label` and `busy_label`, which
  `danger_action/1` takes too). There is no modal component.
- **Menus** are daisyUI dropdowns under the `Menu` hook, whose trigger is the button with
  `aria-haspopup`, or, for a disclosure, the one with `aria-controls` and `aria-expanded`
  (the filter chips, Filter, Jump to date): a click opens and leaves focus on
  the trigger; Enter, Space and ArrowDown open and focus the first item, ArrowUp the last;
  the arrows wrap, Home and End go to the ends, Escape closes and returns focus. The items
  are not tab stops (`tabindex="-1"`, as `<.menu_item>` renders them): Tab closes the menu
  and moves on from its trigger. A field inside a Filter section keeps its own keys, and
  ArrowDown from a section's search goes to its first option. With
  `data-float` the list is a popover in the top layer, placed under its trigger, so no
  scroll region clips it (a row's menu, a list's Filter and Sort). A menu that holds a
  form, such as the runs list's Jump to date, stays open while the page answers it, and
  the page closes it once the form did what it asked: `push_event("menu:close", %{id: id})`.
- **`<.table>`** is a scroll region of its own, focusable and named by its `label`, which
  is required, so a wide table scrolls inside the page and never the page sideways; its
  rows follow the row spec (Lists, above). A column of icons has a header for a screen
  reader (`sr_label`). A settings section is not a named region of its own, so its list
  is the one landmark with the section's name.
- **Tooltips** (`.tooltip` with `data-tip`) take no box while hidden, so a right-hand one
  never widens a phone's page; shown, they wrap at 36ch or the window. Escape hides the
  one under the pointer or focus until the pointer leaves or focus moves (`app.js`).
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
(`ApiaryWeb.Edition`). What it renders there links to its own pages, which handle its
events; a page whose behaviour differs is the edition's own at the same path.

A component does not ask `Apiary.Features` what the instance serves: the page asks with
its scope and passes the answer, as the connection row's `security` attribute does. What
Forager reported is untrusted: a component interpolates it and never passes it to `raw/1`.

### Storybook

In development the components have a storybook, at `/dev/storybook` of the dev server
(<http://localhost:4100/dev/storybook> under `mix phx.server`): `phoenix_storybook`, a
dependency in dev and test only, whose backend is `ApiaryWeb.Storybook`
(`storybook/storybook.ex`). The core's router mounts it where `:dev_routes` is set and the
library is there (`ApiaryWeb.Routes.storybook_routes/0`); a release, and an edition's
router, have none of it.

A story is drawn with the app's own components and stylesheet:
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
`prefers-color-scheme` block does the same. The dark theme is designed on its own, not
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
rather than the browser's. It writes in the words, locale and time zone the server put on
`<body>`, so the server never re-renders for a clock. The full time with its zone is the
`title`. Everything else a person reads as a date, time or number goes through
`ApiaryWeb.Format`.

**Scripts.** A hook lives under `assets/js/hooks/` and is registered in `hooks.js`, the
collection `app.js` and an edition's bundle import. It holds no words (see
[lingo.md](lingo.md)), and keeps in `localStorage` only a reading preference, such as
the theme, the sidebar's fold or the keyboard shortcuts; filters, the order, the page and
a chosen row are query parameters.

**The content security policy.** Every page, the storybook's and the development tools'
included, carries a strict `Content-Security-Policy` (`ApiaryWeb.ContentSecurityPolicy`):
`script-src 'self'` and the request's nonce, so only the console's own bundles and the
scripts that carry the nonce run, and a script a bug lets into a page does not. A page
keeps to it:

- A `<script>` written into a template carries the nonce, `nonce={@csp_nonce}`, as the root
  layout's theme script does. Anything else a page runs is a hook in the bundle.
- No `on…=` attribute (`onclick`, `onload`, …) and no `javascript:` address. A
  `phx-*` binding and a `Phoenix.LiveView.JS` command are not inline script and need
  nothing.
- Scripts, stylesheets, images, fonts and form targets are the console's own origin (an
  image may also be a `data:` address), and no page is framed, except the development
  tools' own pages under `/dev`. Inline styles are allowed (`style-src 'self'
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
width, and from 1440 px the **Details rail** (320 px, sticky under the top bar, scrolling
on its own) sits beside it, on every tab but Terminal, which is wide and takes the
whole width (`q-run-wide`). The top bar's breadcrumb ends with Runs, a link to the list,
and `Run 0191f2a4`, a link to the Timeline on the other tabs; the run's target is on its meta line, not in the breadcrumb, and the
page has no breadcrumb of its own.

- **The header** is the title (the one the run gave in its `about`, else "Run" and the
  run's short id, `Run 0191f2a4`) alone; then, when the run names a kind or subjects, one
  line of what it is about: the kind, then at most three subjects, each its type and ref
  as given and a link out (`<.external_link>`) with its title as the tooltip, then "+N
  more" (all of them are in the rail's About); then one muted meta line that starts with
  the state as a dot and its word (`ApiaryWeb.TargetComponents.state_mark/1`), then, each
  after a faint middle dot, why it ended in words where they say more than the state
  (Ended · quiet for 30 minutes, but not "timed out" beside Timed out), how alive the run
  is while it runs, the target (its page), the runtime, the host, when it
  started, how long it took and its denials, in red, which lead to its denied
  connections. At the right: Close run while the run may be closed, and a ⋯ menu (Copy
  run id, Raw log, Download log). Close run asks in place: the button becomes its
  `inline_confirm/1`, "Close this run?", that a close is final, Yes, close and Cancel,
  never a dialog; Cancel or Escape brings the button back with the focus. The seven
  cells of v1 are the rail's. A run that ended badly says how under the meta line, in one
  cut line whole on hover: the last result of its timeline that was no success, else its
  last failed turn or tool, with "Jump to it", the timeline at that item.
- **The tabs**, Timeline, Terminal, Network access and Details (from 1440 px only on
  Terminal and on Details itself, where there is no rail), stick under the top bar; each is a live action of the one LiveView, so a tab is a patch.
- **The Details rail** is key and value lines under small headings (About, Run, Labels,
  Command, Record, Policy in force), no card and no chip; the run's labels are its own
  identifiers, in mono, and one that names the target leads to its page.
- **About** is the rail's first section, shown when the run names a kind, a subject or
  details: Kind; Subjects, each its type and ref, a link out when its url may be one, with
  its title muted under it, cut to a line and whole on hover; then the details in mono, by
  key, a row per member, a member that is a non-empty object a row per member of its own
  keyed `outer.inner`, a string as given and anything else as compact JSON, each value
  wrapped and never cut. The title is the page's `<h1>` and is not repeated there.
- **A subject's words** (its type, ref and title) are each isolated in a `<bdi>` wherever
  they show, in the runs list, the header and the rail, so a bidirectional character in
  one reorders nothing around it; a subject's link has as its tooltip its title and the
  host its url parses to ("Login redirects to a blank page · tracker.example.com"), or
  the host alone.
- **A run's title and kind** are each isolated in a `<bdi>` wherever they show as markup
  (the run page's `<h1>` and About, the runs list's row and preview, a target's runs, the
  Overview's rows and its Close question, Network access's hits and ⌘K's results), in a
  sentence too (`{:bdi, title}` of `ApiaryWeb.RichText`); a tooltip, the page's `<title>`,
  an `aria-label` and an announcement hold them as plain text. Below 1440 px,
  and from it when Terminal took the rail's room, the Details tab shows this same element
  in the column, its sections as cards
  (`q-run-on-details`), so the two never disagree and no id is drawn twice.
- **The timeline's open items are flat**: a rule in the item's state's colour under the
  chevron, the content indented beside it, code with a faint label and no border, a
  connection line with a plain glyph and no row tint, the prompt as quoted text with a
  rule.
- **The end reason** is in words (`RunComponents.reason_words/1`), the same in the meta
  line and under State in the rail: timed out, closed, gateway lost, session lost, quiet
  for a period, run credential expired, and the issuer reported the run ended
  ([contract-assumptions.md](contract-assumptions.md), How a run ends). The quiet period
  reads in whole hours, else whole minutes, else seconds: 1800 seconds is "quiet for 30
  minutes". The meta line leaves out the exit where it reads as the words ("gateway
  lost").
- **A run with no session**, one a gateway opened for a program that reports none
  (`opened_by` `gateway`, `Apiary.Runs.Run.no_session?/1`), has the same page with what
  the record lacks left out. Its header says its state, Ended for a run that went quiet,
  whose run credential expired or whose issuer reported it ended, and the reason's words
  after it, with no runtime, no host and no exit. The tabs are as on any run: Timeline,
  Terminal, Network access and Details.
  - **Terminal** is the terminal itself, as on a session's run, its bar, its dark screen
    and its foot (Ended · 0 B), empty, with a note in the middle of the screen in the
    terminal's own message style: "**No session.** A gateway opened this run for a
    program that reports none, so there is no terminal output. Its connections are on
    the Network access tab." Search, follow, wrap, the text size and the download are
    disabled, Focus and Full screen stay, and the caption under it is left out (The
    terminal, below).
  - **Timeline** has no notice of its own; the lane key, Main session, and Connections
    inline are as on any run. Run started reads "by a gateway with no session". The last
    item of a run that ended quiet, with its run credential expired or by its issuer
    reads "Run ended", the reason's words and the duration, with a neutral stop mark;
    every other reason keeps "Run exited".
  - **The Details rail**'s Run section: State with the reason's words under it; Opened
    by, "gateway (no session)", second; Key and Node; then Forager, its version and the
    contract's (`0.10.0 · contract 1`), the gateway's; and Instance. There is no Exit,
    Runtime, Host or Wall row, and no Command section. Record's Session reads "none".

  A session's run through a separate gateway looks as any run: its Node is the gateway's,
  and its Host the agent's machine.

## The terminal

`<.terminal>` in `RunPageComponents` is dark in both themes: the recorded output's colours
are written against a dark ground. It fills the window below the tab bar, never under
380 px. The `Terminal` hook reads the bytes from the run's log endpoint and hands them to
xterm.js as `Uint8Array`s, never decoded strings, in slices per frame so a long log does
not block input. The bytes never cross the LiveView socket: the LiveView sends the foot's
numbers and a signal that the log advanced. xterm.js is vendored under
`assets/vendor/xterm`, built as its own bundle and loaded on the hook's first mount, by no
other page. The screen is `role="log"` with `aria-live="off"`.

- **The recorded width is kept.** A run whose record says its pseudo-terminal's size is
  drawn at those columns and rows, centred only inside the box's own darker ground, which
  fills the column; it scrolls inside the box when it is larger. A run on pipes is fitted
  to the box, with Wrap.
- **The bar**: the stream, search (`/`), follow (End), wrap, the **text size** (A−, A+,
  11 to 18 px, and Fit, the largest size at which a recorded screen's columns fit), a
  reading preference kept in `localStorage`; download; **Focus** (`f` outside a field;
  Escape leaves), a class on the root that folds the shell, the header, the tabs and the
  rail away so the box takes the window; and **Full screen**, the browser's, on the box,
  shown only where the browser has it. A narrow box names its buttons on hover only
  (a container query), so the bar never wraps.
- **An empty box with a note.** A run with no session has no log: its Terminal tab is the
  box all the same, bar, screen and foot, with a note in the middle of the screen in the
  terminal's own message style ("No session." and why). While the log is empty, search,
  follow, wrap, the text size and the download are disabled, and the hook reads no log;
  Focus and Full screen stay. The caption under the box is left out. A run with a session
  and no output says so in the column instead, as an empty state.

## Words

Every visible or announced string goes through Gettext in engine words, one whole
sentence per msgid, and markup inside a sentence goes through `ApiaryWeb.RichText`; the
rules are in [lingo.md](lingo.md). A page says organisation and workspace as plain words,
and names the product Qory Apiary.

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
  sidebar has a name of its own: its heading, Main for the first group, else its first
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
  focusing it holds it. A copy is announced politely: a button by its own live span, a
  row's copy by the shell's one `#copy-announcer`, never a live region a row.
- **Motion.** Motion shows cause and effect for what floats; layout, rows and streamed
  inserts never animate. The only loops mean "still being written": the spinner, the
  skeleton and the alive ripple. Under `prefers-reduced-motion: reduce` the global block
  in `app.css` zeroes every duration, the loops stand still, and a hook that scrolls uses
  `behavior: "auto"`.

## Phones and touch

The breakpoint is 768 px (Tailwind's `md`). Below it the sidebar is the drawer, which
scrolls as one piece and holds the sidebar alone (The shell), the gutter is 16 px,
controls are 40 px high and inputs take 16 px text so the browser does not zoom. The
second column is a column from 1024 px and, below it, at every width, one disclosure under
the top bar, `[ Workspace settings · Main ▾ ]`, whose links open in place. On a touch screen (`pointer: coarse`) a small control gets a 40 px hit area
whatever its drawn size. At 320 px wide, and at 200% zoom, the page never scrolls
sideways: tables, code, the filter bar and the terminal scroll inside their own
containers.
