defmodule ApiaryProWeb.SettingsLive.Ownership do
  @moduledoc """
  The ownership of an organisation, a section of its settings (`ApiaryWeb.SettingsComponents`):
  `/:org/settings/ownership`. Its operator, and the arbiter's offer of its ownership
  (`ApiaryPro.Transfers`).

  - An offer of the instance admins to one of its admins, while its owners are all
    suspended, is not withdrawn here; the admin it names reads it at the top of the page,
    with the admins' reason, and accepts it there. Every other page of the organisation
    tells them of it, and leads here (`ApiaryProWeb.Notices`).
  - A client names its operator to all of its people in its Operator part, which says
    who can end it.

  The section is there for a person who has an offer to accept, or who reads a client's
  settings (`tab?/1`); anyone else who opens the path
  is sent to General, told there is nothing here for them. The section is flat, a part
  for the operator and one for the ownership, each with its button and its muted line
  (`ApiaryWeb.SettingsComponents.part/1`, `save/1`). The page follows the membership
  changes an acceptance and a parting tell the people concerned of.
  """
  use ApiaryProWeb, :live_view

  alias Apiary.{Access, Features}
  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.Organisation
  alias ApiaryPro.{Flags, Operators, Tenants, Transfers}
  alias ApiaryProWeb.ConfirmComponents
  alias ApiaryPro.Transfers.Transfer
  alias ApiaryWeb.{People, SettingsComponents, UserAuth}

  @impl true
  # Offering the organisation to an operator is a form page of the section
  # (`ApiaryWeb.PageComponents.page_form/1`): the settings' sections in the second column,
  # the breadcrumb ending Ownership / Transfer to an operator, its title, one
  # sentence, what the transfer does to the features, the operator's address focused, and
  # Offer ownership with Cancel back to Ownership.
  def render(%{live_action: :transfer, transfer_kind: kind, pending: nil} = assigns)
      when not is_nil(kind) do
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
      <:crumb>{gettext("Transfer to an operator")}</:crumb>

      <.page_form
        id="transfer"
        title={gettext("Transfer %{name} to an operator", name: @current_scope.organisation.name)}
        cancel={ownership_path(@current_scope)}
        cancel_by="patch"
      >
        <:description>
          {gettext(
            "An owner of the operator accepts the offer. Then %{name} is its client: its people keep their levels, you included, and the operator's people read everything in it and change nothing. Until then you can withdraw the offer.",
            name: @current_scope.organisation.name
          )}
        </:description>
        <.notice kind={:warning}>
          <span id="transfer-features-warning">
            {gettext(
              "Its features become what the operator grants its clients, which may be fewer than it has now: what the operator does not grant is gone from %{name} until it does.",
              name: @current_scope.organisation.name
            )}
          </span>
        </.notice>
        <.form
          for={@transfer_form}
          id="transfer-form"
          phx-submit="offer_to_operator"
          class="grid gap-4"
          novalidate
        >
          <.input
            field={@transfer_form[:operator_slug]}
            type="text"
            label={gettext("The operator's address")}
            autocomplete="off"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.page_form_foot
            id="transfer-save"
            cancel={ownership_path(@current_scope)}
            cancel_by="patch"
          >
            <.button
              id="transfer-confirm"
              variant="primary"
              type="submit"
              loading_text={gettext("Offering")}
            >
              {gettext("Offer ownership")}
            </.button>
          </.page_form_foot>
        </.form>
      </.page_form>
    </Layouts.app>
    """
  end

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
          <SettingsComponents.save>
            <.button
              :if={may?(@current_scope, :"organisation.leave_operator")}
              id="leave-operator"
              patch={
                if @live_action == :leave,
                  do: ownership_path(@current_scope),
                  else: ~p"/#{@current_scope.organisation}/settings/ownership/leave"
              }
              aria-expanded={to_string(@live_action == :leave)}
              aria-controls={@live_action == :leave && "leave-operator-form"}
            >
              {gettext("Leave %{operator}…", operator: @operator.name)}
            </.button>
            <:note>{ending(@operator)}</:note>
          </SettingsComponents.save>
          <ConfirmComponents.typed_confirm
            :if={@live_action == :leave}
            id="leave-operator"
            question={gettext("Leave %{operator}?", operator: @operator.name)}
            form={@confirm_form}
            change="confirm"
            submit="leave_operator"
            ready={@confirm_form[:name].value == @operator.name}
            button={gettext("Yes, leave")}
            loading_text={gettext("Leaving")}
            cancel={JS.patch(ownership_path(@current_scope)) |> JS.focus(to: "#leave-operator")}
          >
            <:lost>
              {gettext(
                "%{name} leaves %{operator} at once.",
                name: @current_scope.organisation.name,
                operator: @operator.name
              )}
            </:lost>
            <:field>
              <.input
                field={@confirm_form[:name]}
                type="text"
                label={gettext("Type the name of %{name} to confirm", name: @operator.name)}
                autocomplete="off"
                spellcheck="false"
                debounce="0"
              />
            </:field>
          </ConfirmComponents.typed_confirm>
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
          <div
            :if={!@pending && @transfer_kind == :to_operator}
            id="transfer-operator"
            class="grid gap-2"
          >
            <p class="max-w-[60ch] text-muted">
              {gettext(
                "Offer %{name} to an operator, whose harness it then runs. Once an owner of the operator accepts, %{name} is its client: its people keep their levels, you included, and the operator's people read everything in it and change nothing.",
                name: @current_scope.organisation.name
              )}
            </p>
            <p id="transfer-operator-features" class="max-w-[60ch] text-muted">
              {gettext(
                "Its features then become what the operator grants it, which may be fewer than it has now."
              )}
            </p>
          </div>
          <SettingsComponents.save>
            <.button
              :if={
                @pending && !@pending.arbitrated &&
                  may?(@current_scope, :"organisation.withdraw_transfer")
              }
              id="withdraw-transfer"
              patch={
                if @live_action == :withdraw,
                  do: ownership_path(@current_scope),
                  else: ~p"/#{@current_scope.organisation}/settings/ownership/withdraw"
              }
              aria-expanded={to_string(@live_action == :withdraw)}
              aria-controls={@live_action == :withdraw && "withdraw-transfer-confirming"}
            >
              {gettext("Withdraw offer…")}
            </.button>
            <.button
              :if={!@pending && @transfer_kind == :to_operator}
              id="transfer-to-operator"
              patch={~p"/#{@current_scope.organisation}/settings/ownership/transfer"}
            >
              {gettext("Transfer to an operator")}
            </.button>
            <:note>
              {gettext("An offer stays pending until it is accepted or withdrawn.")}
            </:note>
          </SettingsComponents.save>
          <.inline_confirm
            :if={@live_action == :withdraw && @pending}
            id="withdraw-transfer-confirming"
            question={gettext("Withdraw the offer?")}
            cancel={JS.patch(ownership_path(@current_scope)) |> JS.focus(to: "#withdraw-transfer")}
          >
            {withdraw_sentence(@pending, @current_scope.organisation)}
            <:action>
              <.button
                id="withdraw-transfer-confirm"
                variant="danger"
                size="xs"
                phx-click="withdraw_transfer"
                loading_text={gettext("Withdrawing")}
              >
                {gettext("Yes, withdraw")}
              </.button>
            </:action>
          </.inline_confirm>
        </SettingsComponents.part>
      </.settings_page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    hidden!(socket)
    scope = socket.assigns.current_scope

    # A section not in the reader's list sends its path to General, saying why.
    if tab?(scope) do
      {:ok,
       socket
       |> assign(:page_title, title(scope, gettext("Ownership")))
       |> assign_confirm()
       |> assign_transfer()
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

  @impl true
  def handle_params(_params, _uri, socket) do
    hidden!(socket)

    {:noreply, socket |> apply_action(socket.assigns.live_action) |> titled()}
  end

  # While a flag hides its action (`ApiaryPro.Access.hidden?/1`), the offer's page and the
  # confirmations of withdrawing and leaving are not found, as pages that are not there,
  # with nothing said, before the section's redirect. This is not `Apiary.Access.check/3`:
  # with the flag on, leaving an organisation with no operator is not found there, and this
  # page shows that the organisation has no operator any more.
  defp hidden!(%{assigns: %{live_action: live_action}})
       when live_action in [:transfer, :withdraw, :leave] do
    if ApiaryPro.Access.hidden?(action_of(live_action)), do: raise(ApiaryWeb.NotFound)
    :ok
  end

  defp hidden!(_socket), do: :ok

  defp action_of(:transfer), do: :"organisation.transfer"
  defp action_of(:withdraw), do: :"organisation.withdraw_transfer"
  defp action_of(:leave), do: :"organisation.leave_operator"

  # The browser's title names the page: the offer's act, else the section
  # (`ApiaryWeb.SettingsComponents.page_title/3`).
  defp titled(%{assigns: %{live_action: :transfer}} = socket),
    do:
      assign(
        socket,
        :page_title,
        title(socket.assigns.current_scope, gettext("Transfer to an operator"))
      )

  defp titled(socket),
    do: assign(socket, :page_title, title(socket.assigns.current_scope, gettext("Ownership")))

  defp title(scope, words), do: SettingsComponents.page_title(scope, :organisation, [words])

  defp apply_action(socket, :transfer) do
    %{pending: pending, transfer_kind: kind} = socket.assigns

    cond do
      is_nil(kind) -> back(socket, transfer_refused())
      pending -> back(socket, pending_refused())
      true -> assign_transfer(socket)
    end
  end

  defp apply_action(socket, :withdraw) do
    %{current_scope: scope, pending: pending} = socket.assigns

    cond do
      is_nil(pending) -> back(socket, none_pending())
      pending.arbitrated -> back(socket, arbitrated_refused())
      not may?(scope, :"organisation.withdraw_transfer") -> back(socket, transfer_refused())
      true -> socket
    end
  end

  defp apply_action(socket, :leave) do
    %{current_scope: scope, operator: operator} = socket.assigns

    cond do
      is_nil(operator) -> back(socket, no_operator())
      not may?(scope, :"organisation.leave_operator") -> back(socket, leave_refused(operator))
      true -> assign_confirm(socket)
    end
  end

  defp apply_action(socket, :index), do: socket

  # A page or a confirmation the reader may not open: the section, without it, says why.
  defp back(socket, sentence) do
    socket
    |> put_flash(:error, sentence)
    |> push_patch(to: ownership_path(socket.assigns.current_scope))
  end

  @impl true
  def handle_event("confirm", %{"confirm" => params}, socket) do
    {:noreply, assign_confirm(socket, params)}
  end

  def handle_event(
        "offer_to_operator",
        %{"transfer" => %{"operator_slug" => slug} = params},
        socket
      ) do
    scope = socket.assigns.current_scope

    # An empty slug is answered in the field before anything is asked of the organisation.
    with :ok <- if(String.trim(slug) == "", do: :no_slug, else: :ok),
         {:ok, _transfer} <- Transfers.offer_to_operator(scope, slug) do
      socket = load(socket)
      operator = socket.assigns.pending && socket.assigns.pending.operator

      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext(
           "%{name} is offered to %{operator}. It is its client once an owner of %{operator} accepts.",
           name: scope.organisation.name,
           operator: (operator && operator.name) || String.trim(slug)
         )
       )
       |> push_patch(to: ownership_path(scope))}
    else
      :no_slug ->
        {:noreply, assign_transfer(socket, params, :no_slug)}

      {:error, :no_operator} ->
        {:noreply, assign_transfer(socket, params, :no_operator)}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, busy())}

      {:error, reason} ->
        {:noreply, offer_refused(socket, reason)}
    end
  end

  def handle_event("withdraw_transfer", _params, socket) do
    scope = socket.assigns.current_scope

    case Transfers.withdraw(scope) do
      {:ok, _transfer} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:info, gettext("The offer is withdrawn."))
         |> push_patch(to: ownership_path(scope))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(:error, none_pending())
         |> push_patch(to: ownership_path(scope))}

      {:error, :forbidden} ->
        case Transfers.pending(scope) do
          %Transfer{arbitrated: true} ->
            {:noreply,
             socket
             |> load()
             |> put_flash(:error, arbitrated_refused())
             |> push_patch(to: ownership_path(scope))}

          _theirs ->
            {:noreply, ownership_refused(socket, transfer_refused())}
        end

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, busy())}

      {:error, _reason} ->
        {:noreply, ownership_refused(socket, transfer_refused())}
    end
  end

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
        {:noreply,
         ownership_refused(
           socket,
           gettext("Only the admin of %{name} it is offered to accepts its ownership.",
             name: name
           )
         )}

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
        {:noreply, ownership_refused(socket, transfer_refused())}
    end
  end

  def handle_event("leave_operator", params, socket) do
    scope = socket.assigns.current_scope
    operator = socket.assigns.operator
    typed = get_in(params, ["confirm", "name"])

    case Transfers.leave(scope, typed) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("%{name} has left %{operator}. It has no operator now.",
             name: organisation.name,
             operator: (operator && operator.name) || People.former_member()
           )
         )
         |> push_navigate(to: ~p"/#{organisation}/settings")}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, busy())}

      {:error, :confirmation} ->
        {:noreply, assign_confirm(socket, %{"name" => typed}, :name_mismatch)}

      {:error, :not_found} ->
        {:noreply, ownership_refused(socket, no_operator())}

      {:error, _forbidden} ->
        {:noreply, ownership_refused(socket, leave_refused(operator))}
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
    kind = transfer_kind(scope)
    offered_to_me = offered_to_reader?(scope, pending)

    %{
      pending: pending,
      offered_to_me: offered_to_me,
      acceptance_refused: offered_to_me && Transfers.acceptance_refused(scope, pending),
      transfer_kind: kind,
      ownership?:
        not is_nil(kind) or
          (not is_nil(pending) and may?(scope, :"organisation.withdraw_transfer")),
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
  reader of `scope`: for a person with an offer to accept, and anyone who reads a
  client's settings, who reads its operator there. Anyone else's path to it sends them to
  General.
  """
  @spec tab?(Scope.t()) :: boolean
  def tab?(%Scope{organisation: %Organisation{} = organisation} = scope) do
    Tenants.client?(organisation) or
      not is_nil(transfer_kind(scope)) or
      tab_for_offer?(scope, Transfers.pending(scope))
  end

  def tab?(_scope), do: false

  defp tab_for_offer?(_scope, nil), do: false

  defp tab_for_offer?(scope, pending),
    do:
      offered_to_reader?(scope, pending) or
        may?(scope, :"organisation.withdraw_transfer")

  # The organisation's actions are asked of the organisation.
  defp may?(scope, action), do: Access.can?(scope, action, scope.organisation)

  defp ownership_path(scope), do: ~p"/#{scope.organisation}/settings/ownership"

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

  # An offer, a withdrawal, an acceptance or a parting by someone else changes the reach of
  # the people it concerns, who are told (`ApiaryPro.Transfers`): `ApiaryWeb.UserAuth` loads
  # the scope again on that (`ApiaryWeb.UserAuth.on_membership_change/2`), and here the
  # ownership with it.
  defp follow_ownership(socket), do: UserAuth.on_membership_change(socket, &load/1)

  defp transfer_kind(%{organisation: organisation} = scope) do
    cond do
      Tenants.operator?(organisation) -> nil
      not may?(scope, :"organisation.transfer") -> nil
      Tenants.client?(organisation) -> nil
      Features.visible?(scope, :managed_organisations) -> :to_operator
      true -> nil
    end
  end

  # The operator's name typed to confirm leaving it, and whether it was refused.
  defp assign_confirm(socket, params \\ %{}, refused \\ nil) do
    errors =
      case refused do
        :name_mismatch -> [name: {dgettext_noop("errors", "is not the name"), []}]
        nil -> []
      end

    assign(socket, :confirm_form, to_form(params, as: :confirm, errors: errors))
  end

  # The operator's address (its slug) typed on the offer's page, and what refused it,
  # under the field.
  defp assign_transfer(socket, params \\ %{}, refused \\ nil) do
    errors =
      case refused do
        :no_slug ->
          [operator_slug: {dgettext_noop("errors", "Enter the operator's address."), []}]

        :no_operator ->
          [operator_slug: {dgettext_noop("errors", "No operator has that address."), []}]

        nil ->
          []
      end

    assign(socket, :transfer_form, to_form(params, as: :transfer, errors: errors))
  end

  # An offer refused for what the organisation is, or is no longer: the page goes back to
  # the section, which reads the ownership again.
  defp offer_refused(socket, reason) when reason in [:forbidden, :not_found],
    do: ownership_refused(socket, transfer_refused())

  defp offer_refused(socket, reason) do
    sentence =
      case reason do
        :pending ->
          pending_refused()

        :operator ->
          gettext("An operator is not offered to another operator.")

        :client ->
          gettext("A client is not offered to another operator: it leaves its operator first.")

        _other ->
          transfer_refused()
      end

    socket
    |> load()
    |> put_flash(:error, sentence)
    |> push_patch(to: ownership_path(socket.assigns.current_scope))
  end

  # Refused on the membership as it is now, or for an offer that changed meanwhile: the
  # scope and the ownership are read again, and the page goes back to the section. A
  # person who no longer reaches the organisation has been sent to `/` by then.
  defp ownership_refused(socket, sentence) do
    socket = UserAuth.reload_scope(socket)

    if socket.redirected do
      put_flash(socket, :error, gettext("You no longer have access to this workspace."))
    else
      socket
      |> put_flash(:error, sentence)
      |> load()
      |> push_patch(to: ownership_path(socket.assigns.current_scope))
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

  defp transfer_refused,
    do: gettext("Only an owner offers the organisation to an operator or withdraws the offer.")

  # Who can end the client's place beside its operator, under the Operator part: either
  # side, where its owners may leave; else the operator, which drops it.
  defp ending(operator) do
    if Flags.transfers?(),
      do: gettext("Either side can end this at any time."),
      else: gettext("%{operator} can end this at any time.", operator: operator.name)
  end

  defp no_operator, do: gettext("This organisation has no operator any more.")

  defp leave_refused(operator),
    do:
      gettext("Only an owner of this organisation takes it away from %{operator}.",
        operator: (operator && operator.name) || People.former_member()
      )

  defp pending_refused,
    do: gettext("An offer of the ownership is pending already. Withdraw it first.")

  defp none_pending,
    do: gettext("No offer is pending any more: it was accepted or withdrawn meanwhile.")

  defp arbitrated_refused,
    do: gettext("Support made this offer, so it cannot be withdrawn here.")

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
  defp pending_sentence(%Transfer{kind: :to_operator} = pending, organisation) do
    rich_gettext(
      "%{name} was offered to the operator %{operator} on %{date}. Once an owner of %{operator} accepts, it is a client of %{operator}.",
      name: organisation.name,
      operator: {:b, (pending.operator && pending.operator.name) || People.former_member()},
      date: Format.date(pending.inserted_at)
    )
  end

  defp pending_sentence(%Transfer{} = pending, organisation) do
    rich_gettext(
      "Support offered the ownership of %{name} to %{email} on %{date}. Once they accept, they are its owner.",
      name: organisation.name,
      email: {:b, People.email(pending.recipient) || People.former_member()},
      date: Format.date(pending.inserted_at)
    )
  end

  defp withdraw_sentence(%Transfer{} = pending, organisation) do
    gettext(
      "%{operator} can no longer accept %{name}. You can offer it again later.",
      operator: (pending.operator && pending.operator.name) || People.former_member(),
      name: organisation.name
    )
  end
end
