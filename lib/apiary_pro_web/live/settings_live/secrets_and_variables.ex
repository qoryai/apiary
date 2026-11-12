defmodule ApiaryProWeb.SettingsLive.SecretsAndVariables do
  @moduledoc false

  # The organisation settings' Secrets and variables section, which its two pages share:
  # Secrets (`ApiaryProWeb.SettingsLive.Secrets`) and Variables
  # (`ApiaryProWeb.SettingsLive.Variables`), each a tab at a separate address, as the
  # core's workspace page has them (`ApiaryWeb.SecretLive.Index`). Both tabs mark the
  # section's one entry (`ApiaryProWeb.Edition`'s `settings_tabs/1`) current, and both are
  # open to the same people: whoever reads the organisation's secrets reads its variables.
  # That needs the feature `organisation_variables`. Without it, the section is the Secrets
  # page alone, with the keys of the organisation's model providers, for whoever changes
  # them (`provider.write`), while the features `factory` and `secrets` are shown.
  use ApiaryProWeb, :html

  alias Apiary.{Access, Features}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation

  # The section's key in the settings' second column: both tabs and their forms mark it.
  @section :secrets

  @doc false
  def section, do: @section

  @doc false
  # The section's name: its entry, its heading, its tabs' name and the browser's title.
  def title, do: gettext("Secrets and variables")

  @doc false
  # The one sentence under the heading, on both tabs.
  def sentence(organisation),
    do:
      gettext(
        "Secrets and variables that belong to %{organisation}, not to one workspace. A secret is never shown again once it is saved; a variable is plain text.",
        organisation: organisation.name
      )

  @doc false
  # The address of a tab's list.
  def tab_path(organisation, :secrets), do: ~p"/#{organisation}/settings/secrets"
  def tab_path(organisation, :variables), do: ~p"/#{organisation}/settings/variables"

  @doc false
  # Whether the scope's person opens the section: they read the organisation's secrets,
  # and so its variables, or change the keys of its model providers (`keys_shown?/1`).
  def shown?(%Scope{} = scope),
    do: ApiaryPro.OrganisationSecrets.shown?(scope) or keys_shown?(scope)

  def shown?(_scope), do: false

  @doc false
  # Whether the section is the scope's person's for the keys of the organisation's model
  # providers alone: the features `factory` and `secrets` are shown to them, and they change
  # the keys (`provider.write`). A person who only reads the organisation's connections, a
  # member, does not have it.
  def keys_shown?(%Scope{organisation: %Organisation{} = organisation} = scope) do
    Features.visible?(scope, :factory) and Features.visible?(scope, :secrets) and
      Access.can?(scope, :"provider.write", organisation)
  end

  def keys_shown?(_scope), do: false

  @doc false
  # Whether the page was reached from the other tab's list: its status line then says the
  # tab it switched to, as the core's page does within one page. The browser sends the
  # address it came from on a navigation within the console (`_live_referer`).
  def switched?(socket, from) do
    with true <- Phoenix.LiveView.connected?(socket),
         %{"_live_referer" => referer} when is_binary(referer) <-
           Phoenix.LiveView.get_connect_params(socket) do
      URI.parse(referer).path == tab_path(socket.assigns.current_scope.organisation, from)
    else
      _no -> false
    end
  end

  @doc false
  # What the status line says after a switch: the tab, and how many it holds.
  def switch_words(:secrets, number),
    do: gettext("Secrets, %{number}", number: Format.number(number))

  def switch_words(:variables, number),
    do: gettext("Variables, %{number}", number: Format.number(number))

  # The two tabs under the section's heading, Secrets then Variables, each with how many
  # it holds: links to the two pages, in the page's flow (`page_tabs/1`).
  attr :organisation, :any, required: true
  attr :current, :atom, required: true, values: [:secrets, :variables]
  attr :secrets, :integer, required: true
  attr :variables, :integer, required: true

  @doc false
  def tabs(assigns) do
    ~H"""
    <.page_tabs id="secrets-tabs" label={title()} current={@current} place="section">
      <:tab
        key={:secrets}
        navigate={tab_path(@organisation, :secrets)}
        count={@secrets}
      >
        {gettext("Secrets")}
      </:tab>
      <:tab
        key={:variables}
        navigate={tab_path(@organisation, :variables)}
        count={@variables}
      >
        {gettext("Variables")}
      </:tab>
    </.page_tabs>
    """
  end
end
