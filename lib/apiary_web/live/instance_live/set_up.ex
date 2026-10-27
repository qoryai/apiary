defmodule ApiaryWeb.InstanceLive.SetUp do
  # The instance's connections, `/instance/set-up`, for the instance's admins
  # (`Apiary.Access.instance_admin?/1`); anyone else is answered as a path that does not
  # exist. An instance admin is sent here after the instance's set-up, and at every sign-in
  # until they finish or skip the last step (`Apiary.Setup.connections_reviewed?/0`,
  # `ApiaryWeb.UserAuth.signed_in_path/1`).
  #
  # One step a page, `?step=<n>`, from 1: one step for each of the instance's adapters,
  # with the `factory` feature, by name, as Instance settings › Adapters lists them
  # (`ApiaryWeb.InstanceLive.Adapters`); then mail. A number out of range is the first step.
  #
  # Where an adapter's guide gives steps for setting it up (`Apiary.Adapters.guide/2`), an
  # adapter's step shows them under its title while Set up shows, after a first step of
  # Qory Apiary's, Set up, and before a note of Qory Apiary's on Continue; where it gives
  # none, or Set up does not show, no steps show.
  #
  # An adapter's step says whether it is set up: "Set up" once it is configured
  # (`Apiary.Adapters.configured?/1`), with Continue; else "Not set up", with Set up while
  # it can be set up (`ApiaryWeb.AdapterComponents.settable?/3`), which opens the adapter's
  # set-up in a new tab; else a line on why it can't be set up now, and what to do. The step reads the adapters again as a key arrives or an adapter
  # declares where to set it up or connect to it (`Apiary.Adapters.subscribe_keys/2`), so
  # it turns to "Set up" while the page is open.
  #
  # The mail step holds the form of Instance settings › Mail
  # (`ApiaryWeb.InstanceLive.MailForm`), with "Save and send a test"; where the server's
  # environment sets mail, its settings, with Continue. Once the test link is sent, the
  # step is done.
  #
  # Every step has Skip, which leaves the connection as it is: it can be finished later in
  # Instance settings. Finishing or skipping the last step marks the connections reviewed
  # (`Apiary.Setup.review_connections/1`) and sends the admin on, to their organisation's
  # workspace set-up while it has no workspace (`ApiaryWeb.UserAuth.signed_in_path/1`).
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

    adapters = adapters(scope)

    if connected?(socket),
      do: Enum.each(adapters, &Adapters.subscribe_keys(scope, &1.adapter))

    {:ok,
     assign(socket,
       page_title: gettext("Connect %{name}", name: Apiary.ProductName.name()),
       adapters: adapters,
       mail_source: Mail.source(),
       step: 1
     )}
  end

  # The instance's adapters, with the `factory` feature, each with whether it is
  # configured, whether it can be set up now, and, where neither, why not (`blocked/4`).
  defp adapters(scope) do
    if Adapters.authorize_instance(scope) == :ok do
      for adapter <- Adapters.list_adapters(scope) do
        connected = AccessKeys.active_key?(adapter)
        listed = Adapters.listed?(adapter)
        configured = Adapters.configured?(adapter)
        settable = AdapterComponents.settable?(adapter, connected, listed)

        %{
          adapter: adapter,
          configured: configured,
          settable: settable,
          blocked: blocked(adapter, configured or settable, connected, listed)
        }
      end
    else
      []
    end
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
    total = length(socket.assigns.adapters) + 1

    step =
      case Integer.parse(params["step"] || "") do
        {n, ""} when n in 1..total//1 -> n
        _other -> 1
      end

    {:noreply, assign(socket, step: step, total: total)}
  end

  # The adapters read again while the page is open, and the number of steps counted
  # again. The step stays on what it showed: the same adapter, found by its id, or mail;
  # where that adapter is gone, the step at its number, at most the last. An adapter added
  # since is listened to as the others are.
  defp reload_adapters(socket) do
    %{adapters: before, step: step, current_scope: scope} = socket.assigns
    adapters = adapters(scope)
    total = length(adapters) + 1
    known = MapSet.new(before, & &1.adapter.id)

    for %{adapter: adapter} <- adapters,
        adapter.id not in known,
        do: Adapters.subscribe_keys(scope, adapter)

    step =
      case Enum.at(before, step - 1) do
        nil ->
          total

        %{adapter: %{id: id}} ->
          case Enum.find_index(adapters, &(&1.adapter.id == id)) do
            nil -> min(step, total)
            index -> index + 1
          end
      end

    moved? = step != socket.assigns.step
    socket = assign(socket, adapters: adapters, total: total, step: step)

    if moved?,
      do: push_patch(socket, to: ~p"/instance/set-up?#{[step: step]}", replace: true),
      else: socket
  end

  @impl true
  # Skip, or Continue once a step is done: the next step, or, after the last, on.
  def handle_event("next", _params, %{assigns: %{step: step, total: total}} = socket)
      when step < total,
      do: {:noreply, push_patch(socket, to: ~p"/instance/set-up?#{[step: step + 1]}")}

  def handle_event("next", _params, socket), do: {:noreply, finish(socket)}

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

  # A key arrived at an adapter, or it declared where to set it up or connect to it: the
  # adapters read again.
  def handle_info({event, %{node_id: _id}}, socket)
      when event in [:key_enrolled, :adapter_declared],
      do: {:noreply, reload_adapters(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # The connections are reviewed, and the admin goes on as a sign-in sends them.
  defp finish(socket) do
    case Setup.review_connections(socket.assigns.current_scope) do
      :ok -> redirect(socket, to: ~p"/")
      {:error, :forbidden} -> push_navigate(socket, to: ~p"/instance/set-up")
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :row, Enum.at(assigns.adapters, assigns.step - 1))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      memberships={@memberships}
      counts={@nav_counts}
      place={:instance}
      sidebar={false}
    >
      <div id="set-up" class="mx-auto grid w-full max-w-[480px] gap-4 md:pt-6">
        <SetUpComponents.heading step={@total > 1 && @step} total={@total}>
          {gettext("Connect %{name}", name: Apiary.ProductName.name())}
        </SetUpComponents.heading>

        <.adapter_step :if={@row} row={@row} />
        <.mail_step :if={!@row} source={@mail_source} current_scope={@current_scope} />
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true

  # An adapter's step: its name, what setting it up does, the steps its guide gives for
  # setting it up after Qory Apiary's first, where it gives them and while Set up shows,
  # its state, and Set up or Continue.
  defp adapter_step(%{row: %{adapter: adapter} = row} = assigns) do
    assigns =
      assign(assigns,
        adapter: adapter,
        set_up: !row.configured and row.settable,
        guide: Adapters.guide(adapter, :setup)
      )

    ~H"""
    <section id={"set-up-#{@adapter.public_id}"} class="grid gap-4" aria-labelledby="set-up-name">
      <div class="grid gap-1.5">
        <h2 id="set-up-name" class="text-[17px]/6 font-semibold">{@adapter.name}</h2>
        <p id="set-up-what" class="text-sm/5 text-muted">
          {gettext("Set up %{adapter}, so organisations can bring in tickets from %{adapter}.",
            adapter: @adapter.name
          )}
        </p>
      </div>

      <SetUpComponents.guide :if={@set_up && @guide} id="set-up-help" guide={@guide}>
        <:first>
          <.rich text={
            rich_gettext("Press %{button}. A new tab opens.", button: {:b, gettext("Set up")})
          } />
        </:first>
        <:note>
          <.rich text={
            rich_gettext("Come back to this tab. When the state shows %{state}, press %{button}.",
              state: {:b, gettext("Set up")},
              button: {:b, gettext("Continue")}
            )
          } />
        </:note>
      </SetUpComponents.guide>

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
        {blocked_line(@row.blocked, @adapter.name)}
      </p>

      <div class="flex flex-wrap items-start justify-between gap-3 pt-1">
        <div class="flex gap-2">
          <.button
            :if={@row.configured}
            id="set-up-continue"
            type="button"
            variant="primary"
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
            size="sm"
            target="_blank"
          />
        </div>
        <.skip :if={!@row.configured} />
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

  attr :source, :atom, required: true
  attr :current_scope, :map, required: true

  # The mail step: what setting mail up does, its help, and the form of Instance settings ›
  # Mail; where the environment sets mail, its settings, a line to press Continue, and
  # Continue, without the help.
  defp mail_step(assigns) do
    ~H"""
    <section id="set-up-mail" class="grid gap-4" aria-labelledby="set-up-name">
      <div class="grid gap-1.5">
        <h2 id="set-up-name" class="text-[17px]/6 font-semibold">{gettext("Mail")}</h2>
        <p id="set-up-what" class="text-sm/5 text-muted">
          {gettext("Set up mail, so Qory Apiary sends invitations and password links.")}
        </p>
      </div>

      <SetUpComponents.help :if={@source != :env} id="set-up-help">
        <p>
          {gettext(
            "Get the SMTP server's host name, port, username and password from your mail provider."
          )}
        </p>
        <ol>
          <li>
            <.rich text={
              rich_gettext("In %{field}, enter the mail server's host name, such as %{host}.",
                field: {:b, gettext("SMTP relay")},
                host: {:code, "smtp.example.com"}
              )
            } />
          </li>
          <li>
            <.rich text={
              rich_gettext(
                "In %{field}, keep %{starttls} for STARTTLS, or enter %{tls} if your provider uses TLS from the start.",
                field: {:b, gettext("Port")},
                starttls: {:code, "587"},
                tls: {:code, "465"}
              )
            } />
          </li>
          <li>
            <.rich text={
              rich_gettext(
                "In %{username} and %{password}, enter the login your provider gave you. Leave both empty if the relay takes mail without a login.",
                username: {:b, gettext("Username")},
                password: {:b, gettext("Password")}
              )
            } />
          </li>
          <li>
            <.rich text={
              rich_gettext("Press %{button}.", button: {:b, gettext("Save and send a test")})
            } />
          </li>
          <li>
            {gettext(
              "Open the email that Qory Apiary sent to your address, and follow its link while you are signed in."
            )}
          </li>
        </ol>
        <p>
          <.rich text={
            rich_gettext(
              "If the step shows %{line}, mail is set up already, and this step needs nothing from you.",
              line: {:b, gettext("Set by the server's environment")}
            )
          } />
        </p>
      </SetUpComponents.help>

      <.live_component
        module={MailForm}
        id="mail"
        current_scope={@current_scope}
        path={~p"/instance/set-up"}
        step
      >
        <:actions><.skip /></:actions>
      </.live_component>

      <p :if={@source == :env} id="set-up-env" class="text-[13.5px]/5">
        <.rich text={
          rich_gettext("Mail is set by the server's environment. Press %{button}.",
            button: {:b, gettext("Continue")}
          )
        } />
      </p>

      <div :if={@source == :env} class="flex gap-2 pt-1">
        <.button id="set-up-continue" type="button" variant="primary" phx-click="next">
          {gettext("Continue")}
        </.button>
      </div>
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
