defmodule ApiaryWeb.InstanceLive.SetUp do
  # The instance's connections, `/instance/set-up`, for the instance's admins
  # (`Apiary.Access.instance_admin?/1`); anyone else is answered as a path that does not
  # exist. An instance admin is sent here after the instance's set-up, and at every sign-in
  # until they finish or skip the last step (`Apiary.Setup.connections_reviewed?/0`,
  # `ApiaryWeb.UserAuth.signed_in_path/1`).
  #
  # One step a page, in the set-up frame (`ApiaryWeb.SetUpComponents.frame/1`), with the
  # set-up's progress indicator: one step for each of the instance's adapters, with the
  # `factory` feature (`Apiary.Adapters.set_up_list/1`), `?step=<public id>`: first those
  # `QORY_INSTALLED_ADAPTERS` lists, in its order, then the others by name, as Instance
  # settings › Adapters lists them (`ApiaryWeb.InstanceLive.Adapters`); then mail,
  # `?step=mail`, unless the server's environment sets mail (`Apiary.Mail.source/0` is
  # `:env`), which leaves nothing to configure. Without a step, or with one the page does
  # not have, the first step that is not done, else the last; `?step=mail` without the
  # mail step, the first step. With no step at all, the page sends the admin on as a
  # sign-in does, through `/`, and marks nothing. The context column says why the step
  # exists.
  #
  # An adapter listed that the installer has not made yet is a step by its name,
  # `?step=<name>`, which shows that Qory Apiary is adding it, with Back and Skip. The
  # page listens for the adapters the installer makes
  # (`Apiary.Adapters.subscribe_installs/1`), and the step turns into the adapter's step,
  # `?step=<public id>`, without a reload.
  #
  # Where an adapter's guide gives steps for setting it up (`Apiary.Adapters.guide/2`), an
  # adapter's step shows them in the context column, under "In the new tab", while Set up
  # shows; where it gives none, or Set up does not show, no steps show.
  #
  # An adapter's step says whether it is set up: "Set up" once it is configured
  # (`Apiary.Adapters.configured?/1`), with Continue; else "Not set up", with Set up while
  # it can be set up (`ApiaryWeb.AdapterComponents.settable?/3`), which opens the adapter's
  # set-up in a new tab; else a line on why it can't be set up now, and what to do. The
  # step reads the adapters again as a key arrives or an adapter declares where to set it
  # up or connect to it (`Apiary.Adapters.subscribe_keys/2`), so it turns to "Set up"
  # while the page is open.
  #
  # The mail step holds the form of Instance settings › Mail
  # (`ApiaryWeb.InstanceLive.MailForm`), with "Save and send a test", and the saved
  # settings once there are any, with Continue. Once the test link is sent, the step is
  # done.
  #
  # Every step has Back to the step before it, where that step has a page, and Skip while
  # it is not done, which leaves the connection as it is: it can be finished later in
  # Instance settings. Finishing or skipping the last step marks the connections reviewed
  # (`Apiary.Setup.review_connections/1`) and sends the admin to the first step after the
  # connections that is not done: a step of the workspace set-up, such as Name;
  # else on, as a sign-in sends them (`ApiaryWeb.UserAuth.signed_in_path/1`).
  #
  # The page asks for a recent sign-in, as Instance settings › Mail does
  # (`ApiaryWeb.UserAuth`'s sudo mode), for every step: the mail step saves the mail
  # server, and whoever controls the mail receives every log-in link. An instance admin
  # arrives here right after a sign-in.
  #
  # The adapters' steps are of the `factory` feature, and the module reference leaves the
  # module out.
  @moduledoc false

  use ApiaryWeb, :live_view

  on_mount {ApiaryWeb.UserAuth, :require_sudo_mode}

  alias Apiary.{Access, AccessKeys, Adapters, Mail, Setup}
  alias ApiaryWeb.{AdapterComponents, SetUpComponents}
  alias ApiaryWeb.InstanceLive.MailForm

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    unless Access.instance_admin?(scope), do: raise(ApiaryWeb.NotFound)

    # Subscribed before the adapters are read, so a row the installer commits in between
    # still reaches the page.
    if connected?(socket), do: Adapters.subscribe_installs(scope)
    adapters = adapters(scope)

    mail = Mail.source() != :env

    if keys(adapters, mail) == [] do
      {:ok, redirect(socket, to: ~p"/")}
    else
      if connected?(socket),
        do:
          for(%{adapter: %{} = adapter} <- adapters, do: Adapters.subscribe_keys(scope, adapter))

      {:ok,
       assign(socket,
         page_title: gettext("Connect %{name}", name: Apiary.ProductName.name()),
         adapters: adapters,
         mail: mail
       )}
    end
  end

  # The instance's adapters, with the `factory` feature, each with its step's key, whether
  # it is configured, whether it can be set up now, and, where neither, why not
  # (`blocked/4`). An adapter listed that the installer has not made yet has no adapter.
  defp adapters(scope) do
    if Adapters.authorize_instance(scope) == :ok do
      scope |> Adapters.list_adapters() |> Adapters.set_up_list() |> Enum.map(&row/1)
    else
      []
    end
  end

  defp row({:installing, name}),
    do: %{
      key: {:installing, name},
      adapter: nil,
      configured: false,
      settable: false,
      blocked: nil
    }

  defp row(adapter) do
    connected = AccessKeys.active_key?(adapter)
    listed = Adapters.listed?(adapter)
    configured = Adapters.configured?(adapter)
    settable = AdapterComponents.settable?(adapter, connected, listed)

    %{
      key: {:adapter, adapter.public_id},
      adapter: adapter,
      configured: configured,
      settable: settable,
      blocked: blocked(adapter, configured or settable, connected, listed)
    }
  end

  # Why an adapter that is not set up can't be set up now, as
  # `ApiaryWeb.AdapterComponents.settable?/3` decides: it has no key in use; it declares
  # no `setup_url` (and, not configured, no connect address); or it is installed with Qory
  # Apiary and off the list. Nil where it is set up or can be.
  defp blocked(_adapter, true, _connected, _listed), do: nil
  defp blocked(_adapter, false, false, _listed), do: :no_key
  defp blocked(%{setup_url: nil}, false, true, _listed), do: :not_declared
  defp blocked(_adapter, false, true, _listed), do: :not_listed

  @impl true
  def handle_params(params, _uri, socket) do
    %{adapters: adapters, mail: mail} = socket.assigns
    {:noreply, assign_step(socket, step_of(adapters, mail, params["step"]))}
  end

  # The step `?step=` names: an adapter by its public id, one the installer has not made
  # yet by its name, or `mail`, which opens the first step where the page has no mail
  # step. Without one, or with one the page does not have, the first step that is not
  # done, else the last.
  defp step_of(adapters, mail, key) do
    keys = keys(adapters, mail)

    cond do
      key == "mail" ->
        if mail, do: :mail, else: hd(keys)

      row = Enum.find(adapters, &(&1.key in [{:adapter, key}, {:installing, key}])) ->
        row.key

      row = made(adapters, {:installing, key}) ->
        row.key

      row = Enum.find(adapters, &(not &1.configured)) ->
        row.key

      true ->
        List.last(keys)
    end
  end

  defp assign_step(socket, step) do
    assign(socket,
      step: step,
      steps: SetUpComponents.steps_for(socket.assigns.current_scope, step),
      mail_state: Mail.shown().state
    )
  end

  # The adapter the installer made for the step `{:installing, name}`, if any.
  defp made(adapters, {:installing, name}) when is_binary(name),
    do: Enum.find(adapters, &match?(%{adapter: %{installed_as: ^name}}, &1))

  defp made(_adapters, _step), do: nil

  # The page's steps, in order: the adapters', then mail, where it has a step.
  defp keys(adapters, mail),
    do: Enum.map(adapters, & &1.key) ++ if(mail, do: [:mail], else: [])

  defp path_of({:adapter, public_id}), do: ~p"/instance/set-up?#{[step: public_id]}"
  defp path_of({:installing, name}), do: ~p"/instance/set-up?#{[step: name]}"
  defp path_of(:mail), do: ~p"/instance/set-up?step=mail"

  # The adapters read again while the page is open, and the steps counted again. The step
  # stays on what it showed: the same adapter, by its public id, or mail; an adapter the
  # installer has made since, its step; where that adapter is gone, the step at its
  # place, at most the last; with no step left, on through `/`. An adapter added since is
  # listened to as the others are.
  defp reload_adapters(socket) do
    %{adapters: before, step: step, current_scope: scope, mail: mail} = socket.assigns
    adapters = adapters(scope)
    known = for %{adapter: %{id: id}} <- before, into: MapSet.new(), do: id

    for %{adapter: %{} = adapter} <- adapters,
        adapter.id not in known,
        do: Adapters.subscribe_keys(scope, adapter)

    keys = keys(adapters, mail)

    moved =
      cond do
        step in keys ->
          step

        made = made(adapters, step) ->
          made.key

        true ->
          Enum.at(keys, Enum.find_index(keys(before, mail), &(&1 == step)) || 0) ||
            List.last(keys)
      end

    if is_nil(moved) do
      redirect(socket, to: ~p"/")
    else
      socket = socket |> assign(:adapters, adapters) |> assign_step(moved)

      if moved != step,
        do: push_patch(socket, to: path_of(moved), replace: true),
        else: socket
    end
  end

  @impl true
  # Skip, or Continue once a step is done: the next step, or, after the last, on.
  def handle_event("next", _params, %{assigns: %{step: step} = assigns} = socket) do
    case Enum.drop_while(keys(assigns.adapters, assigns.mail), &(&1 != step)) do
      [_step, next | _rest] -> {:noreply, push_patch(socket, to: path_of(next))}
      _last -> {:noreply, finish(socket)}
    end
  end

  # The mail form's events go to the form (`ApiaryWeb.InstanceLive.MailForm`); any other
  # sent to the page is refused in silence, before anything reads it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  # The mail step's test link went out: the last step is done.
  def handle_info({MailForm, :sent}, socket) do
    email = socket.assigns.current_scope.user.email

    {:noreply,
     socket
     |> put_flash(
       :info,
       gettext("Mail turns on when you follow the link we sent to %{email}, signed in as you.",
         email: email
       )
     )
     |> finish()}
  end

  # A key arrived at an adapter, it declared where to set it up or connect to it, or the
  # installer made one: the adapters read again.
  def handle_info({event, %{node_id: _id}}, socket)
      when event in [:key_enrolled, :adapter_declared, :adapter_installed],
      do: {:noreply, reload_adapters(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The connections are reviewed, and the admin goes on to the first step after them that
  # is not done, such as the workspace set-up's Name; else as a sign-in sends them.
  defp finish(socket) do
    %{current_scope: scope, step: step} = socket.assigns

    case Setup.review_connections(scope) do
      :ok ->
        to =
          scope
          |> SetUpComponents.steps_for(step)
          |> Enum.drop_while(&(&1.group != :connect))
          |> Enum.drop_while(&(&1.group == :connect))
          |> Enum.find(&(&1.state != :done and is_binary(&1.path)))

        redirect(socket, to: (to && to.path) || ~p"/")

      {:error, :forbidden} ->
        push_navigate(socket, to: ~p"/instance/set-up")
    end
  end

  @impl true
  def render(assigns) do
    row = Enum.find(assigns.adapters, &(&1.key == assigns.step))
    installing = match?(%{adapter: nil}, row)
    row = if(installing, do: nil, else: row)

    assigns =
      assign(assigns,
        row: row,
        installing: installing && elem(assigns.step, 1),
        guide: row && !row.configured && row.settable && Adapters.guide(row.adapter, :setup)
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      sidebar={false}
    >
      <SetUpComponents.frame
        steps={@steps}
        page={~p"/instance/set-up"}
      >
        <SetUpComponents.heading>
          {gettext("Connect %{name}", name: Apiary.ProductName.name())}
        </SetUpComponents.heading>

        <.adapter_step :if={@row} row={@row} steps={@steps} />
        <.installing_step :if={@installing} name={@installing} steps={@steps} />
        <.mail_step
          :if={@step == :mail}
          state={@mail_state}
          steps={@steps}
          current_scope={@current_scope}
        />

        <:context :if={@row}>
          <p id="set-up-what">
            {gettext(
              "Organisations on this instance bring in tickets from %{adapter} once its adapter is set up. Set up opens the %{adapter} adapter's set-up page in a new tab, and this step shows the new state without a reload.",
              adapter: Adapters.title(@row.adapter)
            )}
          </p>
          <SetUpComponents.outside
            :if={@guide}
            id="set-up-help"
            title={gettext("In the new tab")}
            guide={@guide}
          />
        </:context>
        <:context :if={@step == :mail}>
          <p id="set-up-what">
            {gettext(
              "Qory Apiary sends invitations, log-in links and password links by mail; without mail, an admin copies each link by hand. Get the SMTP server's host name, port, username and password from your mail provider. Mail turns on when you follow the test link that Qory Apiary emails you, while you are signed in."
            )}
          </p>
        </:context>
      </SetUpComponents.frame>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :steps, :list, required: true

  # An adapter's step: its name, its state, why it can't be set up where it can't, and
  # Back, Set up or Continue, and Skip while it is not set up.
  defp adapter_step(%{row: %{adapter: adapter} = row} = assigns) do
    assigns = assign(assigns, adapter: adapter, set_up: !row.configured and row.settable)

    ~H"""
    <section id={"set-up-#{@adapter.public_id}"} class="grid gap-4" aria-labelledby="set-up-name">
      <h2 id="set-up-name" class="text-[17px]/6 font-semibold">{Adapters.title(@adapter)}</h2>

      <p id="set-up-state" class="flex items-center gap-2 text-[13.5px]/5">
        <b class="font-semibold">{gettext("State:")}</b>
        <span :if={@row.configured} class="q-sdot q-sdot-completed">
          <i aria-hidden="true"></i><span>{gettext("Set up")}</span>
        </span>
        <span :if={!@row.configured} class="q-sdot">
          <i aria-hidden="true"></i><span>{gettext("Not set up")}</span>
        </span>
      </p>

      <p :if={@row.blocked} id="set-up-blocked" class="text-[13.5px]/5 text-muted">
        {blocked_line(@row.blocked, Adapters.title(@adapter))}
      </p>

      <div class="q-su-acts">
        <SetUpComponents.back steps={@steps} page={~p"/instance/set-up"} />
        <.button
          :if={@row.configured}
          id="set-up-continue"
          type="button"
          variant="primary"
          size="md"
          phx-click="next"
        >
          {gettext("Continue")}
        </.button>
        <AdapterComponents.setup_form
          :if={@set_up}
          id="set-up-open"
          adapter={@adapter}
          back="list"
          variant="primary"
          size="md"
          target="_blank"
        />
        <span class="grow"></span>
        <.skip :if={!@row.configured} />
      </div>
    </section>
    """
  end

  attr :name, :string, required: true
  attr :steps, :list, required: true

  # The step of an adapter listed that the installer has not made yet: its name, that
  # Qory Apiary is adding it, and Back and Skip.
  defp installing_step(assigns) do
    ~H"""
    <section id={"set-up-installing-#{@name}"} class="grid gap-4" aria-labelledby="set-up-name">
      <h2 id="set-up-name" class="text-[17px]/6 font-semibold">{@name}</h2>

      <p id="set-up-installing" class="text-[13.5px]/5">
        {gettext(
          "Qory Apiary is adding %{name}. This page shows how to set it up once it is added.",
          name: @name
        )}
      </p>

      <div class="q-su-acts">
        <SetUpComponents.back steps={@steps} page={~p"/instance/set-up"} />
        <span class="grow"></span>
        <.skip />
      </div>
    </section>
    """
  end

  # What to do about an adapter that can't be set up now, and why.
  defp blocked_line(:no_key, name),
    do:
      gettext(
        "Connect %{adapter} with an access key in Instance settings › Adapters. It can't be set up until it has a key in use; this step updates once it has one.",
        adapter: name
      )

  defp blocked_line(:not_declared, name),
    do:
      gettext(
        "Check that %{adapter} is running. It has a key in use, but it has not sent the address where it is set up; this step updates once it has.",
        adapter: name
      )

  defp blocked_line(:not_listed, name),
    do:
      gettext(
        "Skip this step. %{adapter} is no longer on the list of adapters installed with Qory Apiary, so it can't be set up.",
        adapter: name
      )

  attr :state, :atom, required: true
  attr :steps, :list, required: true
  attr :current_scope, :map, required: true

  # The mail step: the form of Instance settings › Mail, with Back, Save and send a test,
  # and Skip, or Continue once settings are saved.
  defp mail_step(assigns) do
    ~H"""
    <section id="set-up-mail" class="grid gap-4" aria-labelledby="set-up-name">
      <h2 id="set-up-name" class="text-[17px]/6 font-semibold">{gettext("Mail")}</h2>

      <.live_component
        module={MailForm}
        id="mail"
        current_scope={@current_scope}
        path={~p"/instance/set-up"}
        step
      >
        <:back><SetUpComponents.back steps={@steps} page={~p"/instance/set-up"} /></:back>
        <:actions :if={@state in [:pending, :on]}>
          <.button id="set-up-continue" type="button" size="md" phx-click="next">
            {gettext("Continue")}
          </.button>
        </:actions>
        <:actions :if={@state not in [:pending, :on]}><.skip /></:actions>
      </.live_component>
    </section>
    """
  end

  # Skip, with where the connection can be finished later.
  defp skip(assigns) do
    ~H"""
    <div id="set-up-skip" class="grid justify-items-end gap-1.5 text-right">
      <.button id="set-up-skip-button" type="button" variant="ghost" phx-click="next">
        {gettext("Skip")}
      </.button>
      <p class="max-w-[22ch] text-[12.5px]/4 text-muted">
        {gettext("You can finish this later in Instance settings.")}
      </p>
    </div>
    """
  end
end
