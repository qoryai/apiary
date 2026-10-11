defmodule ApiaryWeb.Edition do
  @moduledoc """
  The web side of the edition (`Apiary.Edition`): what an edition adds to the console's
  pages, named once in the configuration with the router that serves them and the
  application whose static files come first.

      config :apiary, :edition,
        web: MyEditionWeb.Edition,    # this behaviour
        router: MyEditionWeb.Router,  # mounts the core's routes (ApiaryWeb.Routes)
        static_app: :my_edition       # its priv/static served before :apiary's

  The core is an edition of its own, `ApiaryWeb.Edition.Core`, and the default: no
  navigation entry, count, switcher entry, settings tab, slot content, activity words or
  reserved name beyond the core's. A module that `use`s this one gets the core's answer to
  every callback and overrides the ones it changes.

  As with `Apiary.Edition`, the configuration is read at compile time and every call is
  made at runtime on the module it names, so the core compiles without the edition and
  never names one of its modules. The router is called the same way: the endpoint
  dispatches to `router/0` at runtime (`ApiaryWeb.Endpoint`), and
  `ApiaryWeb.Features.Routes` and `ApiaryWeb.ReservedSlugs` answer with it.

  The callbacks, by where they are asked:

  - **Navigation** (`ApiaryWeb.Layouts`): `c:nav_entries/1`, the sidebar's entries after
    the core's, `c:new_entries/2`, what New offers before the core's,
    `c:switcher_entries/1`, the organisation menu's after its places,
    `c:workspace_switcher_entries/1`, the workspace menu's after its workspaces,
    `c:account_menu_entries/1`, the account menu's after the core's, and
    `c:instance_sections/1`, the Instance level's before the core's, each an
    `ApiaryWeb.Nav.Entry`; `c:nav_sections/0`, the headings of the edition's own groups of
    the sidebar; `c:nav_counts/1`, the numbers beside them, merged into
    `ApiaryWeb.UserAuth.nav_counts/1`; `c:place_group/1`, the heading the organisation
    menu lists a place the edition lists (`c:Apiary.Edition.places/1`) under;
    `c:place_scope/2`, which the core no longer asks.
  - **Readers and refusals**: `c:reader_sentence/2`, what the pages say to a person who
    reads an organisation through the edition's reach (`Apiary.Access.reader/1`);
    `c:refusal_sentence/1`, what a page says of a refusal the edition gave.
  - **Pages**: `c:settings_tabs/1`, the sections the organisation's settings add;
    `c:slot/2`, what the edition renders in a named place of a core page
    (`ApiaryWeb.Extension`); `c:activity_describer/0`, the module that says the
    edition's actions in words on the Activity page; `c:above_policy_link/1`, where the
    level above a workspace's policy (`c:Apiary.Edition.above_workspace/1`) is read and
    changed, for the policy pages' "View in …" and Network access's "Change in …".
  - **Paths**: `c:reserved_slugs/0`, the names the edition's own paths take beyond the
    core's (`ApiaryWeb.ReservedSlugs`).
  - **Words**: `c:product_name/0`, the product's name on the button of the Qory Apiary
    menu and as the menu's name (`ApiaryWeb.Layouts.brand_menu/1`);
    `c:gettext_backend/0`, the Gettext backend of the edition's own sentences, beside the
    core's (`ApiaryWeb.Gettext.Backends`).
  """

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Workspace
  alias ApiaryWeb.Nav.Entry

  @doc """
  The edition's entries of the sidebar, after the core's of the same section, in the
  scope of the page; a link of the breadcrumb's menus asks the same entries of the place
  it leads to (`ApiaryWeb.SwitchController`).
  """
  @callback nav_entries(Scope.t()) :: [Entry.t()]

  @doc """
  The edition's counts beside its entries (`ApiaryWeb.Nav.Entry`'s `count`), merged into
  the core's for a scope with an organisation.
  """
  @callback nav_counts(Scope.t()) :: %{atom => term}

  @doc """
  The edition's entries of New, the top bar's menu and the palette's actions, before the
  core's (`ApiaryWeb.Layouts.new_entries/2`), in the scope of the page and its place: a
  workspace's page, an organisation's own, or the person's. Each entry's `action` is
  asked, of the workspace or the organisation as the entry's `place` says, before it is
  offered.
  """
  @callback new_entries(Scope.t(), place :: :workspace | :organisation | :person) :: [Entry.t()]

  @doc """
  The organisation menu's entries, the breadcrumb's menu of the organisations the person
  reaches, after Your organisations, in the scope of the page.
  """
  @callback switcher_entries(Scope.t()) :: [Entry.t()]

  @doc """
  The workspace menu's entries, the breadcrumb's menu of the organisation's workspaces,
  after its workspaces, in the scope of a workspace's page, such as a way to add one;
  none in the core, which has no page that adds a workspace.
  """
  @callback workspace_switcher_entries(Scope.t()) :: [Entry.t()]

  @doc """
  The edition's entries of the account menu, after the core's of the same group
  (`ApiaryWeb.Layouts.account_menu_entries/1`), in the scope of the page: each an
  `ApiaryWeb.Nav.Entry` whose `section` says its group, `:account` (with Settings and
  Your organisations, the default) or `:instance` (after the theme, before Log out), and
  whose `action`, where it has one, is asked of the organisation before it is offered.
  The Instance level is not the account menu's: its Instance settings is in the Qory
  Apiary menu (`c:instance_sections/1`).
  """
  @callback account_menu_entries(Scope.t()) :: [Entry.t()]

  @doc """
  The edition's sections of the Instance level, before the core's Configuration
  (`ApiaryWeb.Layouts.instance_sections/1`): each an `ApiaryWeb.Nav.Entry` with
  `place: :instance` and a path, a string, only those the scope's person may open. The
  Qory Apiary menu's Instance settings, shown to whoever may open one, leads to the
  first; with two or more they open as the second column of the Instance's pages, under
  the heading Instance settings.
  """
  @callback instance_sections(Scope.t()) :: [Entry.t()]

  @doc """
  The edition's own groups of the sidebar, in order, after the core's: each the `section`
  its entries name (`ApiaryWeb.Nav.Entry`) and its heading, translated, or nil for a group
  without one. An entry of a section neither the core nor the edition names goes last,
  without a heading.
  """
  @callback nav_sections() :: [{atom, String.t() | nil}]

  @doc """
  The heading the organisation menu lists a place under (`c:Apiary.Edition.places/1`),
  translated, such as the clients a person reaches through their operator; nil for the
  person's own organisations, which the menu lists first.
  """
  @callback place_group(place :: term) :: String.t() | nil

  @doc """
  The scope a place of the edition's (`c:Apiary.Edition.places/1`), or a membership the
  edition's scope carries more of, gives in `workspace`, as
  `Apiary.Organisations.resolve_scope/4` would load it; nil for the core's own. The core
  no longer asks for it: the breadcrumb's menus link every workspace through
  `ApiaryWeb.SwitchController`, which reads the destination's own scope when the link is
  followed. It stays so that editions which answer it compile.
  """
  @callback place_scope(place :: term, %Workspace{}) :: Scope.t() | nil

  @doc """
  What the pages say to a reader (`Apiary.Access.reader/1`), a person who reads the
  organisation of `scope` through the edition's reach, with no membership there, in a
  role that changes nothing: `:refused`, the sentence of a change a page refuses them. Nil for the
  core's words. The core no longer asks for `:level` (the account menu's line where a
  member's level was); it stays in the type so that editions which answer it compile.
  """
  @callback reader_sentence(:level | :refused, Scope.t()) :: String.t() | nil

  @doc """
  What a page says of a refusal the edition gave, a reason the core does not know, such as
  one of `c:Apiary.Edition.deletion_refusal/2`'s: one sentence, or nil for the page's own
  words for a change that could not be made.
  """
  @callback refusal_sentence(reason :: atom) :: String.t() | nil

  @doc """
  The sections the edition adds to the organisation's settings, each a page of its own, in
  the list beside the settings (`ApiaryWeb.SettingsComponents`), after the core's.
  """
  @callback settings_tabs(Scope.t()) :: [Entry.t()]

  @doc """
  What the edition renders in the named slot of a core page, given the slot's assigns
  (`ApiaryWeb.Extension`), or nil for nothing.
  """
  @callback slot(ApiaryWeb.Extension.name(), assigns :: map) ::
              Phoenix.LiveView.Rendered.t() | nil

  @doc "The module that says the edition's actions in words on the Activity page, or nil."
  @callback activity_describer() :: module | nil

  @doc """
  Where the level above the workspace's policy is read and changed, for the scope's
  reader: its `path`, and `can_change`, whether the reader may change it there; nil where
  the edition keeps no such level, or the reader may not read it. The core's pages draw
  the level's rows and lines from `Apiary.Policy.Effective`'s `above` and link here. A
  link that asks the level to allow a host carries the host as `allow` and, as `back`, the
  path of the workspace's page it was followed from (its overview, its Network access or
  a target's, as filtered), for the level's page to offer the way back once it is done.
  """
  @callback above_policy_link(Scope.t()) :: %{path: String.t(), can_change: boolean} | nil

  @doc """
  The names the edition's own paths take beyond the core's: first segments of the
  instance's paths (`instance`) and pages of an organisation (`organisation`).
  """
  @callback reserved_slugs() :: %{
              optional(:instance) => [String.t()],
              optional(:organisation) => [String.t()]
            }

  @doc """
  The product's name, as the edition names it: the button of the Qory Apiary menu and the
  menu's name (`ApiaryWeb.Layouts.brand_menu/1`), "Qory Apiary" in the core's. A name, not
  a sentence: it is not translated. The log-in pages, the page titles and the emails keep
  "Qory Apiary".
  """
  @callback product_name() :: String.t()

  @doc """
  The edition's Gettext backend, whose catalogues hold the sentences of the edition's own
  modules, or nil when the edition has none beyond the core's `ApiaryWeb.Gettext`. It is
  built as the core's is (`docs/lingo.md`), with a catalogue for every locale of the
  core's. A sentence the core translates without knowing whose it is, such as a
  changeset's error on a form, is looked up in the core's catalogues, then in the
  edition's (`ApiaryWeb.Gettext.Backends`).
  """
  @callback gettext_backend() :: module | nil

  @callbacks [
    nav_entries: 1,
    nav_counts: 1,
    new_entries: 2,
    switcher_entries: 1,
    workspace_switcher_entries: 1,
    account_menu_entries: 1,
    instance_sections: 1,
    nav_sections: 0,
    place_group: 1,
    place_scope: 2,
    reader_sentence: 2,
    refusal_sentence: 1,
    settings_tabs: 1,
    slot: 2,
    activity_describer: 0,
    above_policy_link: 1,
    reserved_slugs: 0,
    product_name: 0,
    gettext_backend: 0
  ]

  defmacro __using__(_opts) do
    defaults =
      for {name, arity} <- @callbacks do
        args = Macro.generate_arguments(arity, __MODULE__)

        quote do
          @impl ApiaryWeb.Edition
          def unquote(name)(unquote_splicing(args)),
            do: ApiaryWeb.Edition.Core.unquote(name)(unquote_splicing(args))
        end
      end

    quote do
      @behaviour ApiaryWeb.Edition
      unquote_splicing(defaults)
      defoverridable ApiaryWeb.Edition
    end
  end

  @config Application.compile_env(:apiary, :edition, [])
  @module Keyword.get(@config, :web, ApiaryWeb.Edition.Core)
  @router Keyword.get(@config, :router, ApiaryWeb.Router)
  @static_app Keyword.get(@config, :static_app, :apiary)

  # An edition that is an application of its own compiles after the core, which depends
  # on nothing of it: its module is not there to check a call against yet.
  @compile {:no_warn_undefined, @module}

  @doc "The module that answers for the edition's web side."
  @spec module() :: module
  def module, do: @module

  @doc """
  The router the endpoint dispatches to: the edition's, which mounts the core's routes
  (`ApiaryWeb.Routes`) and adds its own, or `ApiaryWeb.Router`.
  """
  @spec router() :: module
  def router, do: @router

  @doc """
  The application whose `priv/static` the endpoint serves first, before `:apiary`'s; the
  core's own, `:apiary`, when the edition has none.
  """
  @spec static_app() :: atom
  def static_app, do: @static_app

  # One function per callback, which asks the configured module.
  for {name, arity} <- @callbacks do
    args = Macro.generate_arguments(arity, __MODULE__)
    @doc false
    def unquote(name)(unquote_splicing(args)), do: @module.unquote(name)(unquote_splicing(args))
  end
end
