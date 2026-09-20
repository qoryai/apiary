defmodule ApiaryWeb.HiveLive.Overview do
  @moduledoc """
  The landing after sign-in: the hive, empty, with the one thing to do next.
  """
  use ApiaryWeb, :live_view

  alias Apiary.AccessKeys
  alias Apiary.Organisations

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      nav={:overview}
    >
      <.header>
        {@current_scope.hive.name}
        <:subtitle>
          The <.term word="hive" /> of the
          <span class="font-medium text-ink">{@current_scope.organisation.name}</span>
          <.term word="apiary" />.
        </:subtitle>
      </.header>

      <.empty_state
        :if={@keys == []}
        icon="hero-key"
        title="Connect your first machine"
        class="py-14"
      >
        <p>
          Nothing has posted to this <.term word="hive" /> yet. An access key is all a machine
          needs to start.
        </p>
        <.steps class="mx-auto mt-8 max-w-md text-left" />
        <:actions>
          <.button variant="primary" navigate={~p"/hive/keys/new"}>
            <.icon name="hero-plus-micro" class="size-4" /> Create an access key
          </.button>
        </:actions>
      </.empty_state>

      <div :if={@keys != []} class="space-y-6">
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
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
        </div>

        <.card>
          <:title>Connect a machine</:title>
          <:actions>
            <.button size="sm" navigate={~p"/hive/keys"}>Manage access keys</.button>
          </:actions>
          <.steps />
        </.card>

        <p class="text-sm text-ink-muted">
          Runs will appear here once a machine posts.
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :class, :any, default: nil

  defp steps(assigns) do
    ~H"""
    <ol class={["space-y-4", @class]}>
      <li
        :for={
          {n, title, body} <- [
            {1, "Create an access key",
             "Give it a label such as the machine or environment it is for."},
            {2, "Paste the server block into the runner file",
             "The key dialog shows the block ready to copy. The secret is shown once."},
            {3, "See runs here",
             "From the first post on, every run of that machine lands in this hive."}
          ]
        }
        class="flex gap-3"
      >
        <span class="flex size-6 shrink-0 items-center justify-center rounded-full bg-accent-soft text-xs font-semibold text-accent-soft-ink">
          {n}
        </span>
        <div class="min-w-0">
          <p class="text-sm font-medium text-ink">{title}</p>
          <p class="text-sm text-ink-muted">{body}</p>
        </div>
      </li>
    </ol>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    keys = AccessKeys.list_access_keys(scope)

    {:ok,
     assign(socket,
       page_title: "Overview",
       keys: keys,
       active_keys: Enum.count(keys, &is_nil(&1.revoked_at)),
       members: Organisations.list_members(scope)
     )}
  end

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
