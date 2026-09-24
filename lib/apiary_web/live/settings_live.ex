defmodule ApiaryWeb.SettingsLive do
  @moduledoc """
  Organisation and hive settings: names, the owners, and retention: how long the hive
  keeps a run's events and log output, and what the nightly job last pruned.

  The proof of the body's words (`docs/lingo.md`): every sentence is a gettext call in
  engine words, and the software body's catalogue says organisation and workplace.
  """
  use ApiaryWeb, :live_view

  alias Apiary.Organisations
  alias Apiary.Retention

  import ApiaryWeb.RunPageComponents, only: [format_bytes: 1]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:settings}
      width="narrow"
    >
      <.header>
        {gettext("Settings")}
        <:subtitle>
          {gettext(
            "The names of this organisation and its hive, who owns them, and how long runs are kept."
          )}
        </:subtitle>
      </.header>

      <.notice :if={!@owner?} kind={:info}>
        {gettext("Only owners can change these settings. Ask an owner if a name needs to change.")}
      </.notice>

      <.card>
        <:title>{gettext("Organisation name")}</:title>
        <.form
          for={@organisation_form}
          id="organisation-form"
          phx-change="validate_organisation"
          phx-submit="save_organisation"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@organisation_form[:name]}
            type="text"
            label={gettext("Name")}
            debounce="200"
            autocomplete="off"
            disabled={!@owner?}
            required
          />
        </.form>
        <:footer>
          <span>{gettext("Shown in the sidebar and in invitations.")}</span>
          <.button
            :if={@owner?}
            type="submit"
            form="organisation-form"
            disabled={!@organisation_form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
        </:footer>
      </.card>

      <.card>
        <:title>{gettext("Hive name")}</:title>
        <.form
          for={@hive_form}
          id="hive-form"
          phx-change="validate_hive"
          phx-submit="save_hive"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@hive_form[:name]}
            type="text"
            label={gettext("Name")}
            debounce="200"
            autocomplete="off"
            disabled={!@owner?}
            required
          />
        </.form>
        <:footer>
          <span>{gettext("Shown in the sidebar and as the overview title.")}</span>
          <.button
            :if={@owner?}
            type="submit"
            form="hive-form"
            disabled={!@hive_form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
        </:footer>
      </.card>

      <.card>
        <:title>{gettext("Retention")}</:title>
        <.form
          for={@retention_form}
          id="retention-form"
          phx-change="validate_retention"
          phx-submit="save_retention"
          class="grid max-w-[420px] gap-4"
        >
          <.input
            field={@retention_form[:events_retention_days]}
            type="number"
            label={gettext("Keep a run's events for")}
            placeholder={gettext("Forever")}
            min="1"
            max="3650"
            step="1"
            inputmode="numeric"
            debounce="200"
            disabled={!@owner?}
          />
          <.input
            field={@retention_form[:log_retention_days]}
            type="number"
            label={gettext("Keep a run's log output for")}
            placeholder={gettext("Forever")}
            min="1"
            max="3650"
            step="1"
            inputmode="numeric"
            debounce="200"
            disabled={!@owner?}
          />
        </.form>
        <p class="max-w-[60ch] text-[13px]/[20px] text-muted">
          {gettext(
            "In days; empty keeps everything. A run that ended is pruned whole, counted from its last event: first its log output, then its timeline. The run stays in the list with its state, its counts and its connections, and its page says what was pruned and when. Pruned data comes back only from a backup."
          )}
        </p>
        <:footer>
          <span id="retention-summary">{retention_summary(@current_scope.hive)}</span>
          <.button
            :if={@owner?}
            type="submit"
            form="retention-form"
            disabled={!@retention_form.source.valid?}
            loading_text={gettext("Saving")}
          >
            {gettext("Save")}
          </.button>
        </:footer>
      </.card>

      <.card padding={false}>
        <:title>{gettext("Pruned")}</:title>
        <p :if={@retention_runs == []} id="retention-runs-empty" class="px-5 py-4 text-muted">
          {if retention_set?(@current_scope.hive),
            do: gettext("Nothing has been pruned yet. The job runs every night."),
            else: gettext("Nothing is pruned: this hive keeps everything.")}
        </p>
        <ul :if={@retention_runs != []} id="retention-runs" class="divide-y divide-line">
          <li
            :for={run <- @retention_runs}
            id={"retention-run-#{run.id}"}
            class="flex flex-wrap items-baseline gap-x-2.5 gap-y-0.5 px-5 py-2.5"
          >
            <span class="font-medium tabular-nums">{short_datetime(run.started_at)}</span>
            <.badge :if={run.trigger == "manual"}>{gettext("By hand")}</.badge>
            <.badge :if={!run.complete} color="warning">{gettext("Not finished")}</.badge>
            <span class="w-full text-[13px]/[20px] text-muted">{pruned_sentence(run)}</span>
          </li>
        </ul>
        <:footer>
          <span>
            {ngettext(
              "The last run of the nightly job. It is also a line in the server's log.",
              "The last %{count} runs of the nightly job. Each is also a line in the server's log.",
              length(@retention_runs)
            )}
          </span>
        </:footer>
      </.card>

      <.card padding={false}>
        <:title>{gettext("Owners")}</:title>
        <:actions>
          <.button navigate={~p"/hive/members"}>{gettext("Manage members")}</.button>
        </:actions>
        <ul id="owners" class="divide-y divide-line">
          <li
            :for={owner <- @owners}
            id={"owner-#{owner.id}"}
            class="flex flex-wrap items-center gap-x-2.5 gap-y-1 px-5 py-2.5"
          >
            <.avatar
              name={owner.user.email}
              kind={if owner.user_id == @current_scope.user.id, do: "self", else: "person"}
            />
            <span class="min-w-0 truncate font-medium">{owner.user.email}</span>
            <.badge :if={owner.user_id == @current_scope.user.id}>{gettext("You")}</.badge>
            <span class="ml-auto text-[13px]/[18px] tabular-nums text-faint">
              {gettext("since %{date}", date: short_date(owner.inserted_at))}
            </span>
          </li>
        </ul>
        <:footer>
          <span>{gettext("The last owner cannot be removed or demoted.")}</span>
        </:footer>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(page_title: gettext("Settings"), owner?: Organisations.owner?(scope))
     |> assign_forms()
     |> load_owners()
     |> load_retention_runs()}
  end

  @impl true
  def handle_event("validate_organisation", %{"organisation" => params}, socket) do
    changeset =
      socket.assigns.current_scope.organisation
      |> Organisations.change_organisation(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :organisation_form, to_form(changeset))}
  end

  def handle_event("save_organisation", %{"organisation" => params}, socket) do
    scope = socket.assigns.current_scope

    case Organisations.update_organisation(scope, params) do
      {:ok, organisation} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | organisation: organisation})
         |> assign_forms()
         |> put_flash(:info, gettext("Organisation renamed to %{name}.", name: organisation.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :organisation_form, to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("validate_hive", %{"hive" => params}, socket) do
    changeset =
      socket.assigns.current_scope.hive
      |> Organisations.change_hive(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :hive_form, to_form(changeset))}
  end

  def handle_event("save_hive", %{"hive" => params}, socket) do
    scope = socket.assigns.current_scope

    case Organisations.update_hive(scope, params) do
      {:ok, hive} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | hive: hive})
         |> assign_forms()
         |> put_flash(:info, gettext("Hive renamed to %{name}.", name: hive.name))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :hive_form, to_form(changeset))}

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}
    end
  end

  def handle_event("validate_retention", %{"retention" => params}, socket) do
    changeset =
      socket.assigns.current_scope.hive
      |> Retention.change_retention(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :retention_form, to_form(changeset, as: :retention))}
  end

  def handle_event("save_retention", %{"retention" => params}, socket) do
    scope = socket.assigns.current_scope

    case Retention.update_retention(scope, params) do
      {:ok, hive} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | hive: hive})
         |> assign_forms()
         |> put_flash(:info, gettext("Retention saved.") <> " " <> retention_summary(hive))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :retention_form, to_form(changeset, as: :retention))}

      {:error, :unauthorized} ->
        {:noreply, unauthorized(socket)}
    end
  end

  defp assign_forms(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      organisation_form: to_form(Organisations.change_organisation(scope.organisation)),
      hive_form: to_form(Organisations.change_hive(scope.hive)),
      retention_form: to_form(Retention.change_retention(scope.hive), as: :retention)
    )
  end

  defp load_owners(socket) do
    owners =
      socket.assigns.current_scope
      |> Organisations.list_members()
      |> Enum.filter(&(&1.level == :owner))

    assign(socket, :owners, owners)
  end

  defp load_retention_runs(socket) do
    assign(
      socket,
      :retention_runs,
      Retention.list_retention_runs(socket.assigns.current_scope, 5)
    )
  end

  defp retention_set?(hive),
    do: is_integer(hive.events_retention_days) or is_integer(hive.log_retention_days)

  defp retention_summary(%{events_retention_days: nil, log_retention_days: nil}),
    do: gettext("This hive keeps everything.")

  defp retention_summary(%{events_retention_days: events, log_retention_days: nil}),
    do: gettext("Events and log output are pruned after %{days}.", days: days(events))

  defp retention_summary(%{events_retention_days: nil, log_retention_days: log}),
    do: gettext("Log output is pruned after %{days}; events are kept.", days: days(log))

  defp retention_summary(%{events_retention_days: events, log_retention_days: log}) do
    gettext("Log output is pruned after %{log_days}, events after %{events_days}.",
      log_days: days(log),
      events_days: days(events)
    )
  end

  defp days(n), do: ngettext("%{count} day", "%{count} days", n)

  defp pruned_sentence(%{runs_pruned: 0}), do: gettext("Nothing was old enough to prune.")

  defp pruned_sentence(run) do
    pruned =
      gettext("%{runs}: %{events} and %{bytes} of log output in %{chunks}.",
        runs:
          ngettext("%{number} run", "%{number} runs", run.runs_pruned,
            number: delimited(run.runs_pruned)
          ),
        events:
          ngettext("%{number} event", "%{number} events", run.events_deleted,
            number: delimited(run.events_deleted)
          ),
        bytes: format_bytes(run.log_bytes_deleted),
        chunks:
          ngettext("%{number} chunk", "%{number} chunks", run.log_chunks_deleted,
            number: delimited(run.log_chunks_deleted)
          )
      )

    Enum.join([pruned | cutoffs(run)], " ")
  end

  defp cutoffs(%{log_cutoff: nil, events_cutoff: nil}), do: []

  defp cutoffs(%{log_cutoff: log, events_cutoff: nil}),
    do: [gettext("Pruned log output from before %{date}.", date: short_date(log))]

  defp cutoffs(%{log_cutoff: nil, events_cutoff: events}),
    do: [gettext("Pruned events from before %{date}.", date: short_date(events))]

  defp cutoffs(%{log_cutoff: log, events_cutoff: events}) do
    [
      gettext("Pruned log output from before %{log_date}, events from before %{events_date}.",
        log_date: short_date(log),
        events_date: short_date(events)
      )
    ]
  end

  defp unauthorized(socket) do
    socket
    |> assign(:owner?, false)
    |> assign_forms()
    |> put_flash(:error, gettext("Only owners can change these settings."))
  end
end
