defmodule ApiaryWeb.HiveLive.Overview do
  @moduledoc """
  The landing after sign-in: the hive, with the one thing to do next while it is empty
  and, once machines post, how many runs are alive now. The count follows the hive's
  topic (`Apiary.Runs.topic/1`), so it moves without a reload.
  """
  use ApiaryWeb, :live_view

  alias Apiary.AccessKeys
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Organisations
  alias Apiary.Runs

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      nav={:overview}
    >
      <.header>
        {@current_scope.hive.name}
        <:subtitle>
          The <.term word="hive" /> of the {@current_scope.organisation.name} <.term word="apiary" />.
        </:subtitle>
      </.header>

      <div :if={@keys == []} class="grid gap-4">
        <section
          id="onboarding"
          class="grid overflow-hidden rounded-box border border-line bg-base-100 shadow-xs md:grid-cols-2"
        >
          <div class="grid content-start gap-5 p-5 md:p-7">
            <div>
              <h2 class="text-base/6 font-semibold tracking-[-0.01em]">Connect your first machine</h2>
              <p class="mt-1 text-muted">
                Nothing has posted to this hive yet. An access key is all a machine needs to start.
              </p>
            </div>
            <.connect_steps current={1} />
            <div>
              <.button variant="primary" navigate={~p"/hive/keys/new"} class="max-[479px]:w-full">
                <.icon name="hero-plus-micro" class="size-4" /> Create an access key
              </.button>
            </div>
          </div>
          <div class="hidden content-start gap-3 border-l border-line bg-base-200 p-7 md:grid">
            <p class="text-xs/4 font-medium tracking-[0.005em] text-muted">What you will paste</p>
            <.code_block code={@preview} label="~/.config/qory/runner.yaml" />
            <.listening class="mt-1">Listening for the first post from a machine.</.listening>
          </div>
        </section>
        <.listening class="md:hidden">Listening for the first post from a machine.</.listening>
      </div>

      <div :if={@keys != []} class="grid gap-6">
        <.stats>
          <.stat
            id="runs-alive"
            label="Runs alive now"
            value={@runs_alive}
            hint={alive_hint(@runs_alive)}
            navigate={~p"/hive/runs"}
          />
          <.stat
            label="Access keys"
            value={@active_keys}
            hint={keys_hint(@keys, @active_keys)}
            navigate={~p"/hive/keys"}
          />
          <.stat
            label="Members"
            value={length(@members)}
            hint={owners_hint(@members)}
            navigate={~p"/hive/members"}
          />
        </.stats>

        <.card>
          <:title>Connect a machine</:title>
          <:actions>
            <.button :if={@posted} id="overview-runs" navigate={~p"/hive/runs"}>See the runs</.button>
            <.button navigate={~p"/hive/keys"}>Manage access keys</.button>
          </:actions>
          <.connect_steps current={if @posted, do: 3, else: 2} />
        </.card>

        <.listening :if={!@posted}>Listening for the first post from a machine.</.listening>
      </div>
    </Layouts.app>
    """
  end

  attr :current, :integer, required: true

  defp connect_steps(assigns) do
    ~H"""
    <.steps current={@current}>
      <:step title="Create an access key">Label it after the machine or environment.</:step>
      <:step title="Paste the server block into the runner file">
        The secret is shown once, in the dialog that creates it.
      </:step>
      <:step title="See runs here">
        From the first post on, every run of that machine lands in this hive.
      </:step>
    </.steps>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    keys = AccessKeys.list_access_keys(scope)

    if connected?(socket), do: Runs.subscribe(scope)

    {:ok,
     socket
     |> assign_runs()
     |> assign(
       page_title: "Overview",
       keys: keys,
       active_keys: Enum.count(keys, &is_nil(&1.revoked_at)),
       members: Organisations.list_members(scope),
       preview:
         AccessKeys.server_block(
           %AccessKey{key_id: "············"},
           "························",
           ApiaryWeb.Endpoint.url()
         )
     )}
  end

  @impl true
  def handle_info({:run_changed, _run}, socket), do: {:noreply, assign_runs(socket)}

  # Counted again on every change: a run becomes alive, ends, is lost or is closed in
  # more ways than a page should reason about, and the count is one indexed query.
  defp assign_runs(socket) do
    scope = socket.assigns.current_scope
    alive = Runs.count_alive(scope)

    posted = alive > 0 or socket.assigns[:posted] == true or Runs.list_runs(scope, limit: 1) != []

    assign(socket, runs_alive: alive, posted: posted)
  end

  defp alive_hint(0), do: "none running"
  defp alive_hint(_alive), do: "starting or running"

  defp keys_hint(keys, active) do
    case length(keys) - active do
      0 -> "active"
      1 -> "active, 1 revoked"
      n -> "active, #{n} revoked"
    end
  end

  defp owners_hint(members) do
    case Enum.count(members, &(&1.level == :owner)) do
      1 -> "1 owner"
      n -> "#{n} owners"
    end
  end
end
