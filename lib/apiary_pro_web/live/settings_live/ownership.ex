defmodule ApiaryProWeb.SettingsLive.Ownership do
  @moduledoc """
  The ownership of an organisation, a section of its settings (`ApiaryWeb.SettingsComponents`):
  `/:org/settings/ownership`. Its operator, and the arbiter's offer of its ownership
  (`ApiaryPro.Transfers`).

  - An offer of the instance admins to one of its admins, while its owners are all
    suspended, is not withdrawn here; the admin it names reads it at the top of the page,
    with the admins' reason, and accepts it there. Every other page of the organisation
    tells them of it, and leads here (`ApiaryProWeb.Notices`).
  - A client names its operator to all of its people in its Operator part.
  - An owner reads the offer pending in its Ownership part, while the config flag
    `transfers` is on, and cannot withdraw it.

  The section is there for a person who has an offer to accept or reads a pending one, or
  who reads a client's settings (`tab?/1`); anyone else who opens the path is sent to
  General, told there is nothing here for them. The section is flat, a part for the
  operator and one for the ownership (`ApiaryWeb.SettingsComponents.part/1`). The page
  follows the membership changes an acceptance tells the people concerned of.
  """
  use ApiaryProWeb, :live_view

  alias Apiary.Access
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.{Flags, Operators, Tenants, Transfers}
  alias ApiaryPro.Transfers.Transfer
  alias ApiaryWeb.{People, SettingsComponents, UserAuth}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts && Map.delete(@nav_counts, :ownership_offer)}
      nav={:organisation}
      sections={@sections}
      section={:ownership}
    >
      <.settings_page section={:ownership} title={gettext("Ownership")}>
        <:subtitle>
          {subtitle(@operator, @ownership? or @offered_to_me)}
        </:subtitle>

        <.notice :if={@offered_to_me} kind={:info}>
          <%!-- The offer, its reason, then what the admin can do: accept, or why not yet. --%>
          <div id="ownership-offer" class="grid justify-items-start gap-2">
            <p>{offer_to_me_sentence(@current_scope.organisation)}</p>
            <p :if={@pending.arbitrated && @pending.reason} id="ownership-offer-reason">
              {gettext("Their reason: %{reason}", reason: @pending.reason)}
            </p>
            <.button
              :if={!@acceptance_refused}
              id="accept-ownership"
              variant="primary"
              size="xs"
              phx-click="accept_transfer"
              loading_text={gettext("Accepting")}
            >
              {gettext("Accept ownership")}
            </.button>
            <p :if={@acceptance_refused} id="ownership-offer-waits" class="font-medium">
              <.rich text={acceptance_waits(@acceptance_refused)} />
            </p>
          </div>
        </.notice>

        <%!-- A part has its heading where the section has two. --%>
        <SettingsComponents.part
          :if={@operator}
          id="operator"
          title={@ownership? && gettext("Operator")}
        >
          <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
            <.avatar name={@operator.name} kind="organisation" />
            <span id="operator-name" class="min-w-0 truncate font-medium">{@operator.name}</span>
            <span class="text-[12.5px] text-muted">{gettext("Operator")}</span>
          </div>
          <p class="max-w-[60ch] text-muted">
            {operator_sentence(@current_scope.organisation, @operator)}
          </p>
        </SettingsComponents.part>

        <SettingsComponents.part
          :if={@ownership?}
          id="ownership"
          title={@operator && gettext("Ownership")}
        >
          <div :if={@pending} id="ownership-pending" class="grid gap-3">
            <p class="max-w-[60ch]">
              <.rich text={pending_sentence(@pending, @current_scope.organisation)} />
            </p>
            <p :if={@pending.arbitrated && @pending.reason} class="max-w-[60ch] text-muted">
              {gettext("Their reason: %{reason}", reason: @pending.reason)}
            </p>
            <p :if={@pending.arbitrated} id="ownership-arbitrated" class="max-w-[60ch] text-muted">
              {gettext("Support made this offer, so it cannot be withdrawn here.")}
            </p>
          </div>
        </SettingsComponents.part>
      </.settings_page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    # A section not in the reader's list sends its path to General, saying why.
    if tab?(scope) do
      {:ok,
       socket
       |> assign(:page_title, title(scope, gettext("Ownership")))
       |> load()
       |> follow_ownership()}
    else
      {:ok,
       socket
       |> put_flash(
         :error,
         gettext("There is nothing about the ownership of %{name} for you to do here.",
           name: scope.organisation.name
         )
       )
       |> push_navigate(to: ~p"/#{scope.organisation}/settings")}
    end
  end

  defp title(scope, words), do: SettingsComponents.page_title(scope, :organisation, [words])

  @impl true
  def handle_event("accept_transfer", _params, socket) do
    scope = socket.assigns.current_scope
    name = scope.organisation.name

    case Transfers.accept(scope) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("You are the owner of %{name} now.", name: organisation.name)
         )
         |> push_navigate(to: ~p"/#{organisation}/settings")}

      {:error, :not_found} ->
        {:noreply,
         ownership_refused(
           socket,
           gettext("No ownership is offered to you here any more: the offer was withdrawn.")
         )}

      {:error, :forbidden} ->
        {:noreply, ownership_refused(socket, accept_refused(name))}

      {:error, :suspended} ->
        {:noreply,
         ownership_refused(
           socket,
           gettext("%{name} is suspended: its ownership does not change until it is activated.",
             name: name
           )
         )}

      {:error, :has_owner} ->
        {:noreply, ownership_refused(socket, acceptance_waits(:has_owner))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, busy())}

      {:error, _reason} ->
        {:noreply, ownership_refused(socket, accept_refused(name))}
    end
  end

  @doc """
  state/1 is the ownership of the organisation of `scope`, as its page shows it to the
  reader: the pending offer, whether it is offered to them and why they could not accept
  it now, whether the Ownership part is theirs to read, and a client's operator. Two
  reads: the offer and the operator.
  """
  @spec state(Scope.t()) :: map
  def state(%Scope{} = scope) do
    pending = Transfers.pending(scope)
    offered_to_me = offered_to_reader?(scope, pending)

    %{
      pending: pending,
      offered_to_me: offered_to_me,
      acceptance_refused: offered_to_me && Transfers.acceptance_refused(scope, pending),
      ownership?: reads_pending?(scope, pending),
      operator: Operators.operator_of(scope)
    }
  end

  @doc """
  offered_to_reader?/2 is true when `pending` offers the organisation to the reader of
  `scope`: `Apiary.Access.check/3` finds the offer for them. A recipient who is no longer
  an admin gets `:forbidden`, and still reads the offer: Accept shows why the acceptance
  fails.
  """
  @spec offered_to_reader?(Scope.t(), Transfer.t() | nil) :: boolean
  def offered_to_reader?(_scope, nil), do: false

  def offered_to_reader?(scope, %Transfer{} = pending) do
    Access.check(scope, :"organisation.accept_transfer", pending) != {:error, :not_found}
  end

  @doc """
  tab?/1 says whether the organisation's settings list the Ownership section for the
  reader of `scope`: for a person with an offer to accept or who reads a pending one, and
  anyone who reads a client's settings, who reads its operator there. Anyone else's path
  to it sends them to General.
  """
  @spec tab?(Scope.t()) :: boolean
  def tab?(%Scope{organisation: %Organisation{} = organisation} = scope) do
    pending = Transfers.pending(scope)

    Tenants.client?(organisation) or offered_to_reader?(scope, pending) or
      reads_pending?(scope, pending)
  end

  def tab?(_scope), do: false

  # An owner reads the offer pending in the Ownership part, while
  # `ApiaryPro.Flags.transfers?/0` is on: `organisation.withdraw_transfer`, which that flag
  # gates, is the action an owner holds over the offer.
  defp reads_pending?(_scope, nil), do: false
  defp reads_pending?(scope, _pending), do: may?(scope, :"organisation.withdraw_transfer")

  # The organisation's actions are asked of the organisation.
  defp may?(scope, action), do: Access.can?(scope, action, scope.organisation)

  # The section's line under its title, of what the page holds for the reader: the
  # operator, where the organisation is a client; offers of its ownership, where there is
  # an Ownership part or an offer to accept.
  defp subtitle(operator, offers?) do
    cond do
      operator && offers? ->
        gettext("Whose harness this organisation runs, and offers of its ownership.")

      operator ->
        gettext("Whose harness this organisation runs.")

      true ->
        gettext("Offers of the ownership of this organisation.")
    end
  end

  # What the page shows, and the sections beside it, read again after a change. The offer
  # is this page's notice: the navigation's counts carry it for the other pages' notice
  # (`ApiaryProWeb.Edition.nav_counts/1`), which this page leaves out of the counts it
  # passes on.
  defp load(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(state(scope))
    |> assign(:sections, SettingsComponents.sections(scope, :organisation))
  end

  # An offer, its lapse or its acceptance by someone else changes the reach of the people
  # it concerns, who are told (`ApiaryPro.Transfers`): `ApiaryWeb.UserAuth` loads
  # the scope again on that (`ApiaryWeb.UserAuth.on_membership_change/2`), and here the
  # ownership with it.
  defp follow_ownership(socket), do: UserAuth.on_membership_change(socket, &load/1)

  # Refused on the membership as it is now, or for an offer that changed meanwhile: the
  # scope and the ownership are read again. A person who no longer reaches the
  # organisation has been sent to `/` by then.
  defp ownership_refused(socket, sentence) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected do
      put_flash(socket, :error, gettext("You no longer have access to this workspace."))
    else
      socket
      |> put_flash(:error, sentence)
      |> load()
    end
  end

  # A change made at the same moment as another, which the database made wait and then
  # broke off rather than let the two wait on each other: nothing is changed.
  defp busy,
    do: gettext("Someone changed this at the same moment, so nothing was changed. Try again.")

  # Why the Accept button is not offered, in a sentence: the page would be refused.
  defp acceptance_waits(:suspended),
    do:
      rich_gettext("It is suspended. %{contact_support}; once it is activated, you can accept.",
        contact_support: ApiaryWeb.Support.rich()
      )

  defp acceptance_waits(:has_owner),
    do: gettext("An owner of it can act again, so the offer no longer stands.")

  defp accept_refused(name),
    do: gettext("Only the admin of %{name} it is offered to accepts its ownership.", name: name)

  # What the operator is to a client: while it owns its clients
  # (`ApiaryPro.Flags.operator_infrastructure?/0`), their owner; else a reader of them.
  defp operator_sentence(organisation, operator) do
    if Flags.operator_infrastructure?() do
      gettext(
        "%{name} runs the harness %{operator} provides. %{operator} owns it: its owners and admins run its workspaces, machines and keys, and its members read everything in it.",
        name: organisation.name,
        operator: operator.name
      )
    else
      gettext(
        "%{name} runs the harness %{operator} provides. The people of %{operator} read everything in %{name} to support its harness, and change nothing.",
        name: organisation.name,
        operator: operator.name
      )
    end
  end

  # The arbiter's offer, as the notice at the top says it.
  defp offer_to_me_sentence(organisation) do
    gettext(
      "Support offers you the ownership of %{name}. When you accept, you are its owner.",
      name: organisation.name
    )
  end

  # The pending offer, as the Ownership part says it: to whom, by whom, and since when.
  defp pending_sentence(%Transfer{} = pending, organisation) do
    rich_gettext(
      "Support offered the ownership of %{name} to %{email} on %{date}. Once they accept, they are its owner.",
      name: organisation.name,
      email: {:b, People.email(pending.recipient) || People.former_member()},
      date: Format.date(pending.inserted_at)
    )
  end
end
