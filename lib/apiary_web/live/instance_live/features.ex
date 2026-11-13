defmodule ApiaryWeb.InstanceLive.Features do
  @moduledoc """
  Instance settings › Features, `/instance/features`: the instance's features
  (`Apiary.Features`), turned on and off by the instance's admins, who may save them
  (`instance.features_save`, asked in the instance scope, `ApiaryWeb.Access`'s
  `:instance`); anyone else is answered as a path that does not exist
  (`ApiaryWeb.NotFound`). It is the Instance level's second section, after General
  (`ApiaryWeb.Layouts.instance_sections/1`).

  One row a feature, in the order of `Apiary.Features.all/0`: its title, with the name
  `QORY_FEATURES` takes in small type, one sentence of what it adds, the features it needs,
  and its switch. A locked feature (`Apiary.Features.Saved.locks/0`) shows why, and its
  switch, if it has one, cannot be turned: `observability` has none.

  The page is a form. A switch changes only the form: turned off, it also turns off, in the
  form, the switches of the features that need it, which stay off when it is turned back
  on. Above **Save** the page shows, for each row whose change turns other features on or
  off, which ones
  (`Apiary.Features.Saved.preview/2`), and, where the list the form would save differs
  from the one in force and runs are running, how many. **Save** saves the list with the
  version it was read at (`Apiary.Features.Saved.save/3`): the features take effect on
  every node at once. A save made from an older read shows why and reads the list again.

  While `QORY_FEATURES` is set and not blank (`Apiary.Features.Saved.env?/0`), its
  features apply: the page shows that once, at the top, and every switch is read only.
  """
  use ApiaryWeb, :live_view

  on_mount {ApiaryWeb.Access, :instance}

  alias Apiary.{Access, Features}
  alias Apiary.Features.Saved
  alias ApiaryWeb.SettingsComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      section={:features}
    >
      <.settings_page section={:features} title={gettext("Features")}>
        <:subtitle>
          {pgettext(
            "plain",
            "Turn features on or off for every organisation. Save applies them at once, with no restart."
          )}
        </:subtitle>

        <SettingsComponents.part id="features">
          <p :if={@env} id="features-env" class="text-[13px]/[20px]">
            <.rich text={
              rich_gettext("Set by the server's environment (%{variable}); change it there.",
                variable: {:code, "QORY_FEATURES", "q-mono"}
              )
            } />
          </p>

          <.form
            for={%{}}
            as={:features}
            id="features-form"
            phx-submit="save"
            class="q-form"
            novalidate
          >
            <ul id="features-rows" class="m-0 list-none p-0">
              <li
                :for={row <- @rows}
                id={"feature-#{row.name}"}
                class="flex items-start justify-between gap-6 border-t border-line py-3 first:border-t-0 first:pt-0"
              >
                <div class="flex min-w-0 flex-col gap-0.5 text-[13px]/[20px]">
                  <p class="m-0">
                    <span id={"feature-#{row.name}-title"} class="font-medium">{row.title}</span>
                    <span id={"feature-#{row.name}-name"} class="q-mono ml-1.5 text-[12px] text-faint">
                      {row.name}
                    </span>
                  </p>
                  <p :if={row.sentence} id={"feature-#{row.name}-sentence"} class="m-0 text-muted">
                    {row.sentence}
                  </p>
                  <p
                    :if={row.needs}
                    id={"feature-#{row.name}-needs"}
                    class="m-0 text-[12px] text-faint"
                  >
                    {row.needs}
                  </p>
                  <p
                    :if={row.reason}
                    id={"feature-#{row.name}-reason"}
                    class="m-0 text-[12px] text-faint"
                  >
                    <.rich text={row.reason} />
                  </p>
                </div>
                <button
                  :if={row.switch}
                  id={"feature-#{row.name}-switch"}
                  type="button"
                  role="switch"
                  class="q-toggle mt-0.5 flex-none"
                  aria-checked={to_string(row.on)}
                  aria-labelledby={"feature-#{row.name}-title"}
                  disabled={!row.may}
                  phx-click={row.may && "toggle"}
                  phx-value-feature={row.name}
                ></button>
              </li>
            </ul>

            <div
              :if={@preview != [] or @running > 0}
              id="features-preview"
              class="flex flex-col gap-1 text-[13px]/[20px]"
            >
              <p
                :for={change <- @preview}
                id={"features-preview-#{change.feature}"}
                class="m-0"
              >
                {preview_line(change)}
              </p>
              <p :if={@running > 0} id="features-running" class="m-0 text-muted">
                {running_line(@running)}
              </p>
            </div>

            <SettingsComponents.save :if={!@env} id="features-save">
              <.button type="submit" variant="primary" loading_text={gettext("Saving")}>
                {gettext("Save")}
              </.button>
            </SettingsComponents.save>
          </.form>
        </SettingsComponents.part>
      </.settings_page>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    instance = socket.assigns.scope

    if Access.can?(instance, :"instance.features_save", instance.organisation) do
      {:ok,
       socket
       |> assign(
         page_title:
           SettingsComponents.page_title(socket.assigns.current_scope, :instance, [
             gettext("Features")
           ])
       )
       |> read()}
    else
      raise ApiaryWeb.NotFound
    end
  end

  @impl true
  def handle_event("toggle", %{"feature" => name}, socket) when is_binary(name) do
    %{env: env, locks: locks, wanted: wanted} = socket.assigns

    feature = Enum.find(Features.all(), &(Atom.to_string(&1) == name))

    # A name that is no feature, a locked one, or any while the variable applies, turns
    # nothing.
    # A switch turned off also turns off, in the form, every feature that needs it,
    # directly or through another; turned back on, it leaves them off.
    if feature && not env && not Map.has_key?(locks, feature) do
      wanted =
        if feature in wanted,
          do: Saved.close(wanted, List.delete(wanted, feature)),
          else: Enum.filter(Features.all(), &(&1 in [feature | wanted]))

      {:noreply, socket |> assign(wanted: wanted) |> form_state()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", _params, socket) do
    %{current_scope: scope, wanted: wanted, version: version} = socket.assigns

    case Saved.save(scope, wanted, version) do
      {:ok, _current} ->
        {:noreply, socket |> put_flash(:info, gettext("Features saved.")) |> read()}

      # Another instance admin saved after this page read the list: the page reads it again.
      {:error, :stale} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext(
             "Check the features again and save. Another instance admin saved them at the same time, so your change was not saved."
           )
         )
         |> read()}

      # QORY_FEATURES applies now: the page shows that, read only.
      {:error, :env} ->
        {:noreply, read(socket)}

      # A lock set since the page read the list, or one the change reaches through the
      # needs: the form stays, and the locked rows show their reasons as they are now.
      {:error, {:locked, _feature}} ->
        {:noreply, socket |> assign(locks: Saved.locks()) |> form_state()}

      # A name that is no feature, which the switches never send, or a database whose
      # migration of the saved features has not run yet: the form stays.
      {:error, reason} when reason in [:unknown_feature, :not_migrated] ->
        {:noreply, socket}

      # No longer an instance admin: the page itself is not found now.
      {:error, reason} when reason in [:forbidden, :not_found] ->
        {:noreply, push_navigate(socket, to: ~p"/instance/features")}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The list in force, its version, the locks and whether the variable applies, read now,
  # and the form set to that list.
  defp read(socket) do
    %{features: features, version: version} = Saved.current()

    socket
    |> assign(
      current: features,
      version: version,
      wanted: features,
      locks: Saved.locks(),
      env: Saved.env?()
    )
    |> form_state()
  end

  # The rows, the preview lines and the running runs, for the form as it is.
  defp form_state(socket) do
    %{current: current, wanted: wanted, locks: locks, env: env} = socket.assigns

    running =
      if Saved.close(current, wanted) != current, do: Saved.running_runs(), else: 0

    assign(socket,
      rows: Enum.map(Features.all(), &row(&1, wanted, locks, env)),
      preview: preview(current, wanted),
      running: running
    )
  end

  # The preview lines: each row that changes others, but a row turned off with another
  # row turned off, whose line already lists it.
  defp preview(current, wanted) do
    changes = Saved.preview(current, wanted)
    off_with = for %{turns: :off, with: with} <- changes, feature <- with, do: feature

    Enum.filter(changes, fn change ->
      change.with != [] and not (change.turns == :off and change.feature in off_with)
    end)
  end

  defp row(feature, wanted, locks, env) do
    lock = Map.get(locks, feature)

    %{
      name: Atom.to_string(feature),
      title: title(feature),
      sentence: sentence(feature),
      needs: needs_line(feature),
      reason: reason(lock),
      switch: lock != {:on, :always},
      on: if(lock, do: elem(lock, 0) == :on, else: feature in wanted),
      may: is_nil(lock) and not env
    }
  end

  defp reason(nil), do: nil
  defp reason({:on, :always}), do: gettext("Every instance has it.")

  defp reason({:off, :no_registry}),
    do:
      rich_gettext("Set %{variable} on the server to turn this on.",
        variable: {:code, "QORY_REGISTRY", "q-mono"}
      )

  defp reason({:on, :installed_adapters}),
    do:
      gettext(
        "Work items stays on while adapters are set in the server's environment. Remove them there to turn it off."
      )

  defp reason({:on, {:needed_by, feature}}),
    do:
      gettext(
        "%{feature} needs it, and stays on while adapters are set in the server's environment. Remove them there to turn it off.",
        feature: title(feature)
      )

  defp needs_line(feature) do
    case Features.needs(feature) do
      [] -> nil
      needs -> gettext("Needs %{features}.", features: titles(needs))
    end
  end

  defp preview_line(%{feature: feature, turns: :on, with: with}),
    do:
      gettext("Turning on %{feature} also turns on %{features}.",
        feature: title(feature),
        features: titles(with)
      )

  defp preview_line(%{feature: feature, turns: :off, with: with}),
    do:
      gettext("Turning off %{feature} also turns off %{features}.",
        feature: title(feature),
        features: titles(with)
      )

  defp running_line(count),
    do:
      ngettext(
        "1 run is running. It finishes with the features it started with.",
        "%{count} runs are running. They finish with the features they started with.",
        count
      )

  @doc """
  titles/1 is the titles of `features`, joined with commas and a last "and": "Work items
  and Process versions". A comma comes before "and" in a list of three or more, and in a
  list of two where a title contains "and": "Security policy, and Secrets and variables".
  A name that is no feature of this release is shown as it is.
  """
  @spec titles([Features.feature() | String.t()]) :: String.t()
  def titles([one]), do: title(one)

  def titles([_first | _rest] = features) do
    titles = Enum.map(features, &title/1)
    {list, [last]} = Enum.split(titles, -1)

    if length(titles) == 2 and not Enum.any?(titles, &String.contains?(&1, " and ")),
      do: gettext("%{first} and %{last}", first: hd(list), last: last),
      else: gettext("%{list}, and %{last}", list: Enum.join(list, ", "), last: last)
  end

  @doc """
  title/1 is a feature's title on this page and in the Activity of its save, by its atom
  or its name; a name this page has no title for is shown as it is.
  """
  @spec title(Features.feature() | String.t()) :: String.t()
  def title(feature) when is_binary(feature) do
    case Enum.find(Features.all(), &(Atom.to_string(&1) == feature)) do
      nil -> feature
      known -> title_of(known)
    end
  end

  def title(feature) when is_atom(feature), do: title_of(feature)

  defp title_of(:observability), do: gettext("Record and runs")
  defp title_of(:security), do: gettext("Security policy")
  defp title_of(:secrets), do: gettext("Secrets and variables")
  defp title_of(:path_rules), do: gettext("Paths in policy rules")
  defp title_of(:factory), do: gettext("Work items")
  defp title_of(:registry), do: gettext("Image registry")
  defp title_of(:workflow_model), do: gettext("Process versions")
  defp title_of(:managed_organisations), do: gettext("Operators and clients")
  defp title_of(:organisation_policy), do: gettext("Organisation policy")
  defp title_of(:organisation_variables), do: gettext("Organisation secrets and variables")
  defp title_of(:feature_visibility), do: gettext("Features by person")
  defp title_of(feature), do: to_string(feature)

  # One sentence of what a feature adds; none for a feature this page does not describe.
  defp sentence(:observability),
    do:
      gettext(
        "The record, the runs with their terminals and timelines, the connections, and retention."
      )

  defp sentence(:security),
    do: gettext("The security policy, and the run configuration sent to gateways.")

  defp sentence(:secrets),
    do: gettext("Stored secrets and variables, and the organisation's integrations.")

  defp sentence(:path_rules), do: gettext("The Paths field of a policy rule's form.")

  defp sentence(:factory),
    do:
      gettext(
        "The work items of a workspace and where they are taken in from, with the set-up steps they need, such as model providers, model and workflow."
      )

  defp sentence(:registry),
    do: gettext("Tokens for the private image registry, and each run's registry credential.")

  defp sentence(:workflow_model),
    do:
      gettext(
        "Changes to each workspace's process: its stages, their workflows and gates, as numbered and trial versions. With it off, each workspace keeps version 1 of its process."
      )

  defp sentence(:managed_organisations),
    do: gettext("Operators and their clients, and what an operator does for them.")

  defp sentence(:organisation_policy),
    do:
      gettext(
        "The organisation's policy above its workspaces' security policy: host rules, the lowest mode and the switch."
      )

  defp sentence(:organisation_variables),
    do:
      gettext(
        "The organisation's secrets beside each workspace's, and its variables, which every workspace inherits."
      )

  defp sentence(:feature_visibility),
    do:
      gettext(
        "What a person is shown depends on who they are, not only on the organisation they are in."
      )

  defp sentence(_feature), do: nil
end
