defmodule ApiaryWeb.Edition.Core do
  @moduledoc """
  The core's web edition, and the default (`ApiaryWeb.Edition`): the console's pages as
  the core has them, with nothing added. No navigation entry, group, count, entry of New,
  entry of the organisation menu or the workspace menu, account menu entry, Instance
  section, group of places or place, settings tab or part of Instance settings ›
  Configuration beyond the core's, every slot empty, no words for a reader, a refusal or
  actions beyond the core's, the core's words for who may take an action, no level above
  a workspace's policy to link to, no reserved name beyond the core's, the product named
  Qory Apiary, no Gettext backend beside the core's, the core's sentences of whose
  workspaces an organisation's gateways reach, the core's words for who manages the
  nodes, and the core's sentences on People.

  An edition that `use`s `ApiaryWeb.Edition` answers as this module does for every
  callback it does not override.
  """

  @behaviour ApiaryWeb.Edition

  use Gettext, backend: ApiaryWeb.Gettext

  @impl true
  def nav_entries(_scope), do: []

  @impl true
  def nav_counts(_scope), do: %{}

  @impl true
  def new_entries(_scope, _place), do: []

  @impl true
  def switcher_entries(_scope), do: []

  @impl true
  def workspace_switcher_entries(_scope), do: []

  @impl true
  def account_menu_entries(_scope), do: []

  @impl true
  def instance_sections(_scope), do: []

  @impl true
  def nav_sections, do: []

  @impl true
  def place_group(_place), do: nil

  @impl true
  def place_scope(_place, _workspace), do: nil

  @impl true
  def reader_sentence(_where, _scope), do: nil

  @impl true
  def refusal_sentence(_reason), do: nil

  @impl true
  def level_refusal_sentence(_reason, _scope), do: nil

  @impl true
  def who_may_sentence(_about, _scope), do: nil

  @impl true
  def settings_tabs(_scope), do: []

  @impl true
  def configuration_parts(_scope), do: []

  @impl true
  def slot(_name, _assigns), do: nil

  @impl true
  def activity_describer, do: nil

  @impl true
  def activity_actor(_entry, _assigns), do: nil

  @impl true
  def above_policy_link(_scope), do: nil

  @impl true
  def reserved_slugs, do: %{}

  @impl true
  def product_name, do: "Qory Apiary"

  @impl true
  def gettext_backend, do: nil

  @impl true
  def gateway_reach_sentence(:intro, organisation),
    do:
      gettext(
        "Nodes in any workspace of %{organisation} can use the gateways added here. A workspace can also add gateways that only its nodes use.",
        organisation: organisation.name
      )

  def gateway_reach_sentence(:who_can_use, organisation),
    do:
      gettext("Nodes in any workspace of %{organisation} can use it.",
        organisation: organisation.name
      )

  def gateway_reach_sentence(:default_row, organisation),
    do:
      gettext("The default gateway for workspaces in %{organisation} that don't set one.",
        organisation: organisation.name
      )

  def gateway_reach_sentence(:empty, organisation),
    do:
      gettext("Add one so the nodes in %{organisation}'s workspaces can send runs through it.",
        organisation: organisation.name
      )

  @impl true
  def nodes_managed_by_sentence(_organisation), do: nil

  @impl true
  def people_sentence(_about, _scope, _bindings), do: nil
end
