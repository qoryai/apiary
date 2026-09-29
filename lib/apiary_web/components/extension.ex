defmodule ApiaryWeb.Extension do
  @moduledoc """
  The named places of the core's pages where an edition renders what it adds
  (`c:ApiaryWeb.Edition.slot/2`): a notice, a link to one of its pages, a control. A core
  page places a slot with `slot/1`, and it renders what the edition returns, or nothing:
  in the core every slot is empty, and the page is as it would be without it.

  The rule: a small addition goes through a slot or a settings tab
  (`c:ApiaryWeb.Edition.settings_tabs/1`), and a page whose behaviour differs is the
  edition's own page at the same path (`ApiaryWeb.Routes`). What a slot renders links to
  the edition's pages and never handles an event in the core's LiveView.

  | Slot | Where | Assigns beside `scope` |
  |---|---|---|
  | `:notices` | every page of an organisation, under the top bar, before the page | `organisation`, `counts` (the navigation's, `ApiaryWeb.UserAuth.nav_counts/1`, or nil) |
  | `:members_heading` | the members page, in its header, under its description | |
  | `:member_access` | each row of the members page, beside the member's name: one line of muted text | `member` |
  | `:member_actions` | each row of the members page, in its ⋯ menu before the page's own items: `CoreComponents.menu_item/1`s | `member` |
  | `:workspace_actions` | each workspace of the organisation's settings, in its ⋯ menu before the page's own items: `CoreComponents.menu_item/1`s | `workspace` |
  | `:policy_notices` | the workspace's policy page, above its tabs' content | `changes`, the number of the policy's changes: it renders the slot again as the policy changes |
  | `:activity_toolbar` | the Activity page, right under its header (reserved) | |
  | `:activity_filters` | the Activity page's filter bar, after its filters (reserved) | |

  `scope` is the page's `Apiary.Accounts.Scope`. A slot's content is rendered again when
  what the page passes it changes; an edition that reads for it reads then, not on
  every render of the page.
  """

  import Phoenix.Component, only: [assign: 3, sigil_H: 2]

  @names [
    :notices,
    :members_heading,
    :member_access,
    :member_actions,
    :workspace_actions,
    :policy_notices,
    :activity_toolbar,
    :activity_filters
  ]

  @typedoc "The name of a slot of a core page."
  @type name ::
          :notices
          | :members_heading
          | :member_access
          | :member_actions
          | :workspace_actions
          | :policy_notices
          | :activity_toolbar
          | :activity_filters

  @doc "names/0 lists the slots of the core's pages."
  @spec names() :: [name]
  def names, do: @names

  @doc """
  slot/1 renders what the edition renders in the slot `name`, given every attribute the
  page passes: `scope`, and what the slot names beside it.

      <ApiaryWeb.Extension.slot name={:notices} scope={@current_scope} organisation={@organisation} />

  A name that is not a slot of the core's pages raises `ArgumentError`.
  """
  @spec slot(map) :: Phoenix.LiveView.Rendered.t()
  def slot(%{name: name} = assigns) when name in @names do
    assigns = assign(assigns, :rendered, ApiaryWeb.Edition.slot(name, assigns))

    ~H"{@rendered}"
  end

  def slot(%{name: name}),
    do: raise(ArgumentError, "no slot #{inspect(name)}, one of #{inspect(@names)}")
end
