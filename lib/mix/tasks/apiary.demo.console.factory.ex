defmodule Mix.Tasks.Apiary.Demo.Console.Factory do
  @moduledoc false

  # The factory part of `mix apiary.demo.console`, with the `factory` feature on: two
  # adapters of the instance, each connected for Acme.
  #
  #   * Tracker, with its repositories, their tickets and their comments, and work items
  #     of those tickets in the states a run of the queue reaches without a gateway.
  #   * Helpdesk, a source that is no forge: its words are incident and queue, its two
  #     queues have no target, and its incidents have none, so none is taken in. The
  #     queues go to the workspace Support where the edition's limit
  #     (`Apiary.Edition.limits/0`, which a workspace's creation checks) allows more than
  #     one workspace, and to Main where it allows one.
  #
  # Each step calls the context function that the request or the page calls:
  #
  #   * Dana, an instance admin who signed in a minute ago, makes each adapter and its
  #     enrolment code (`Apiary.Adapters.create_adapter/2`, `create_code/2`); the adapter
  #     enrols its key with that code (`Apiary.AccessKeys.enrol/2`);
  #   * the adapter declares itself (`Apiary.Adapters.declare/3`), lists its
  #     collections (`Apiary.Adapters.Collections.post_listing/2`), and posts their
  #     tickets and comments (`Apiary.Sources.post_items/2`, `post_comments/2`), each body
  #     read by the contract's wire module first and each request recorded as a use of
  #     its key, as the adapter's signed requests would be;
  #   * Dana connects Acme (`Apiary.Adapters.connect/2`), and comes back with the
  #     adapter's return (`Apiary.Adapters.Connections.complete_return/4`); she makes
  #     Support where the edition allows it (`Apiary.Organisations.create_workspace/2`),
  #     assigns the collections (`Apiary.Adapters.Collections.assign_collections/4`) and
  #     turns one repository's Backlog off (`set_collection_backlog/4`);
  #   * members take tickets in, close and undo (`Apiary.WorkItems`), each under their
  #     scope.
  #
  # The key pair each adapter enrols is made here and kept in memory only: its secret
  # signs the enrolment's proof and the connect return, and is then dropped.
  #
  # Left out: a claim of a run (`Apiary.Dispatches.claim/3`) needs a gateway with a key,
  # which the demo has none of, so no run is claimed, ends or gives a result, and no work item
  # waits for an answer, waits at Confirm, is confirmed, is declined or is sent to Explore
  # again: each of those needs a run that ended.

  import Ecto.Query

  alias Apiary.{AccessKeys, Adapters, Organisations, Repo, Sources}
  alias Apiary.Accounts
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Connections}
  alias Apiary.Adapters.Wire, as: AdapterWire
  alias Apiary.Contract.{Ed25519, Enrolment, SignedMessage}
  alias Apiary.Sources.Backlog
  alias Apiary.Sources.Item
  alias Apiary.Sources.Wire, as: SourceWire
  alias Apiary.WorkItems
  alias Apiary.WorkItems.WorkItem
  alias Mix.Tasks.Apiary.Demo.Shell

  @host "https://tracker.example.com"
  @helpdesk_host "https://helpdesk.example.com"
  # The code host the repositories' runs would clone from.
  @code_host "git.example.com"

  # The repositories, by path: where each is assigned. `:second` is Shop ops where the
  # edition allows it, and Main where it does not.
  @repositories [
    {"acme/shop", :main},
    {"acme/api", :main},
    {"acme/mobile", :main},
    {"acme/web", :main},
    {"acme/billing", :main},
    {"acme/docs", :main},
    {"acme/infra", :main},
    {"acme/warehouse", :second},
    {"acme/sandbox", :none}
  ]

  # The repository whose Backlog Dana turns off once its tickets are in.
  @backlog_off "acme/infra"

  # The people of the tracker, by who they are at the source.
  @filers %{
    dana: {"Dana", "person"},
    lea: {"Lea", "person"},
    mirek: {"Mirek", "person"},
    priya: {"Priya", "person"},
    sam: {"Sam", "person"},
    jonas: {"Jonas", "person"},
    amara: {"Amara", "person"},
    reporter: {"Error reporter", "automation"},
    deps: {"Dependency bot", "automation"},
    monitor: {"Status monitor", "automation"}
  }

  # The tickets: repository, number, type, title, labels, filer, state, comments, days
  # since it was filed, and the line its body opens with.
  @tickets [
    {"acme/shop", 101, "bug", "Checkout total ignores the voucher after a reload",
     ["bug", "checkout"], :lea, "open", 3, 4,
     "Reloading the payment step drops the voucher from the total, but the order is " <>
       "still charged at the reduced price."},
    {"acme/shop", 102, "bug", "Basket badge shows 0 after signing in", ["bug"], :sam, "open", 1,
     9, "The badge counts the guest basket, not the merged one."},
    {"acme/shop", 103, "feature", "Save a basket for later", ["enhancement"], :priya, "open", 2,
     21, "Customers ask to park a basket without checking out."},
    {"acme/shop", 104, "bug", "Product images load twice on the listing page", ["performance"],
     :jonas, "open", 0, 6,
     "The listing fetches each image once for the thumbnail and once for the zoom."},
    {"acme/shop", 105, "bug", "TypeError in the address form after autofill", ["bug", "frontend"],
     :reporter, "open", 4, 2, "Reported 37 times in the last day."},
    {"acme/shop", 106, "task", "Remove the old promotion banner", ["cleanup"], :dana, "open", 0,
     12, "The autumn promotion ended; the banner code is still shipped."},
    {"acme/shop", 107, "feature", "Show delivery dates on the product page",
     ["enhancement", "checkout"], :amara, "open", 2, 15,
     "The warehouse API gives a date per postcode; the page shows none."},
    {"acme/shop", 108, "bug", "Search returns no results for words with umlauts",
     ["bug", "search"], :mirek, "open", 1, 8, "Searching for Kühlschrank finds nothing."},
    {"acme/shop", 109, "bug", "Coupon field accepts expired codes", ["bug", "checkout"], :lea,
     "closed", 2, 30, "Expired codes pass the form and fail at payment."},
    {"acme/shop", 110, "task", "Upgrade the payment library to 4.2", ["dependencies"], :deps,
     "closed", 0, 26, "Version 4.2 fixes a rounding fault in refunds."},
    {"acme/api", 201, "bug", "Orders endpoint times out with more than 500 lines",
     ["bug", "performance"], :priya, "open", 3, 5,
     "Large wholesale orders take more than 30 seconds to load."},
    {"acme/api", 202, "feature", "Return a cursor from the customers list", ["enhancement"],
     :jonas, "open", 1, 18, "Offset paging skips rows while customers are added."},
    {"acme/api", 203, "bug", "Rate limit headers are missing on 429 answers", ["bug"], :sam,
     "open", 0, 7, "Clients cannot tell when to retry."},
    {"acme/api", 204, "bug", "NullPointer in the invoice export", ["bug"], :reporter, "open", 2,
     1, "Reported 12 times since the last deploy."},
    {"acme/api", 205, "task", "Document the webhook retry schedule", ["docs"], :amara, "open", 1,
     11, "Partners ask how often a failed delivery is retried."},
    {"acme/api", 206, "feature", "Accept an idempotency key on POST /payments",
     ["enhancement", "payments"], :mirek, "open", 4, 23,
     "A retried request after a timeout can charge twice."},
    {"acme/api", 207, "bug", "Health check reports ok while the database is down", ["bug"], :dana,
     "closed", 1, 34, "The check only pings the process."},
    {"acme/api", 208, "task", "Bump the JSON library to 1.5", ["dependencies"], :deps, "closed",
     0, 28, "Version 1.5 drops a deprecated option the API still sets."},
    {"acme/mobile", 301, "bug", "App crashes when the camera permission is refused",
     ["bug", "camera"], :reporter, "open", 3, 3, "Seen on phones with less than 2 GB of memory."},
    {"acme/mobile", 302, "feature", "Dark mode for the order history", ["enhancement"], :lea,
     "open", 2, 19, "The history screen is the last one without a dark theme."},
    {"acme/mobile", 303, "bug", "Push notifications arrive twice", ["bug", "notifications"], :sam,
     "open", 1, 10, "Each status change sends two notifications."},
    {"acme/mobile", 304, "task", "Move the build to the new signing key", ["release"], :priya,
     "open", 0, 14, "The current key expires next month."},
    {"acme/mobile", 305, "bug", "Prices round wrongly in the Swiss store", ["bug"], :amara,
     "open", 2, 6, "CHF prices show five-cent steps in the basket only."},
    {"acme/mobile", 306, "bug", "Login screen freezes on slow networks", ["bug"], :jonas,
     "closed", 1, 31, "The spinner never stops when the request times out."},
    {"acme/web", 401, "bug", "Footer links open in the wrong language", ["bug", "i18n"], :mirek,
     "open", 1, 5, "German pages link to the English help."},
    {"acme/web", 402, "feature", "Add a sitemap for the help centre", ["enhancement", "seo"],
     :priya, "open", 0, 17, "Search engines find a third of the help pages."},
    {"acme/web", 403, "bug", "Cookie banner hides the checkout button on phones",
     ["bug", "frontend"], :lea, "open", 3, 4, "On a 360 px screen the banner covers it."},
    {"acme/web", 404, "task", "Replace the font files with variable fonts", ["performance"],
     :dana, "open", 0, 20, "Four font files load on every page."},
    {"acme/web", 405, "bug", "Contact form sends an empty subject", ["bug"], :sam, "closed", 1,
     27, "Support receives the messages without a subject line."},
    {"acme/billing", 501, "bug", "Credit notes skip a number after a failed export",
     ["bug", "invoicing"], :amara, "open", 2, 7, "Auditors ask for a gapless sequence."},
    {"acme/billing", 502, "feature", "Send the invoice PDF in the customer's language",
     ["enhancement", "i18n"], :jonas, "open", 1, 16, "Every invoice is in English today."},
    {"acme/billing", 503, "bug", "VAT is applied twice to shipping in Austria", ["bug"], :mirek,
     "open", 3, 9, "Orders with express shipping are overcharged."},
    {"acme/billing", 504, "task", "Archive the 2023 invoices", ["cleanup"], :dana, "closed", 0,
     40, "They are past the retention period."},
    {"acme/docs", 601, "task", "Describe the new returns policy", ["docs"], :priya, "open", 1, 8,
     "The policy changed on the first of the month."},
    {"acme/docs", 602, "bug", "Broken links in the API reference", ["docs", "bug"], :sam, "open",
     0, 13, "Twelve links point to the old domain."},
    {"acme/docs", 603, "task", "Add screenshots to the onboarding guide", ["docs"], :lea,
     "closed", 2, 29, "New staff ask for them."},
    {"acme/infra", 701, "task", "Rotate the staging database password", ["security"], :dana,
     "open", 0, 6, "It was last rotated a year ago."},
    {"acme/infra", 702, "bug", "Nightly backup job exceeds its window", ["bug", "ops"], :mirek,
     "open", 2, 11, "The job runs into the morning traffic."},
    {"acme/infra", 703, "task", "Upgrade the load balancer image", ["dependencies"], :deps,
     "open", 0, 3, "The image has a fixed security advisory."},
    {"acme/warehouse", 801, "bug", "Pick list prints items out of shelf order", ["bug"], :amara,
     "open", 1, 5, "Pickers walk the aisles twice."},
    {"acme/warehouse", 802, "feature", "Scan a parcel to mark it shipped", ["enhancement"],
     :jonas, "open", 2, 12, "Staff type the parcel number by hand."},
    {"acme/warehouse", 803, "bug", "Stock count is off by one after a return", ["bug"], :sam,
     "open", 0, 4, "Returned items are counted twice."}
  ]

  # The comments a ticket's thread draws from, in turn.
  @comments [
    {:lea, "I can reproduce this on the staging build from this morning."},
    {:mirek, "This started with the last release. The **release notes** list no change here."},
    {:priya, "Customers reported it twice to support this week."},
    {:sam,
     "A first try is on the branch `fix/next-try`:\n\n- tests added\n- " <>
       "staging not tried yet"},
    {:dana, "Agreed, this is worth doing this sprint."},
    {:jonas, "Logs from the last run:\n\n```\nERROR request timed out after 30000 ms\n```"},
    {:amara, "Is this the same as the report from the partner last month?"}
  ]

  # Helpdesk's queues, and their incidents, as `@tickets` has its tickets.
  @queues ["acme/customer-support", "acme/billing-support"]

  @incidents [
    {"acme/customer-support", 901, "incident", "Customers cannot reset their password", ["login"],
     :monitor, "open", 2, 1,
     "The reset mail is not sent; 42 customers wrote in since this morning."},
    {"acme/customer-support", 902, "incident", "Order confirmation shows the wrong address",
     ["orders"], :lea, "open", 1, 2, "Three customers sent screenshots of another address."},
    {"acme/customer-support", 903, "incident", "Chat widget does not load on the help pages",
     ["help centre"], :monitor, "open", 0, 0, "The widget answers 503 since 06:10 UTC."},
    {"acme/customer-support", 904, "incident", "Parcel tracking link opens an empty page",
     ["delivery"], :sam, "open", 1, 3, "The link misses the parcel number for express orders."},
    {"acme/customer-support", 905, "incident", "Gift cards show a zero balance", ["payments"],
     :amara, "open", 0, 4, "The balance shows after a second reload."},
    {"acme/customer-support", 906, "incident", "Newsletter sign-up returns an error",
     ["marketing"], :jonas, "closed", 1, 9, "The form posts to the old endpoint."},
    {"acme/customer-support", 907, "incident", "Store opening hours are wrong for Sundays",
     ["stores"], :priya, "closed", 0, 12, "The page shows weekday hours on Sundays."},
    {"acme/billing-support", 911, "incident", "Card payments fail for amounts over 1,000 EUR",
     ["payments"], :monitor, "open", 2, 0, "The payment step answers declined for every card."},
    {"acme/billing-support", 912, "incident", "Refund mails go out without the amount",
     ["refunds"], :mirek, "open", 0, 3, "The amount field in the mail is empty."},
    {"acme/billing-support", 913, "incident", "Invoice download asks customers to sign in twice",
     ["invoicing"], :dana, "open", 1, 5, "The second sign-in starts after the first succeeds."},
    {"acme/billing-support", 914, "incident", "Direct debit dates are a day late", ["payments"],
     :priya, "closed", 1, 15, "Debits for the first of the month arrive on the second."},
    {"acme/billing-support", 915, "incident", "Credit note PDF is blank", ["invoicing"], :monitor,
     "closed", 0, 20, "The PDF has a page and no text."}
  ]

  # The comments an incident's thread draws from, in turn.
  @incident_comments [
    {:lea, "Support has a reply template for this now."},
    {:monitor, "Checks fail in **2 of 3** regions:\n\n- eu-west: down\n- eu-central: down"},
    {:mirek, "A fix is deployed to staging; production follows at 14:00 UTC."},
    {:dana, "Customers who wrote in get a voucher once this is closed."}
  ]

  # The work items, in the order they are taken in: who takes the ticket in, the ticket by
  # its repository and number, what then happens to it, and its first instruction.
  #
  #   * `:queued`, taken in, its first run waiting;
  #   * `:closed`, taken in and closed;
  #   * `:undone`, taken in and undone, back in the Backlog.
  @work_items [
    {"priya", "acme/api", 201, :queued, "Measure the endpoint with 1,000 lines first."},
    {"jonas", "acme/web", 403, :queued, ""},
    {"mirek", "acme/shop", 106, :queued, ""},
    {"amara", "acme/api", 205, :queued, "Link the page from the webhook settings."},
    {"lea", "acme/shop", 101, :queued, "Keep the voucher in the session, not the form."},
    {"sam", "acme/api", 203, :queued, ""},
    {"dana", "acme/mobile", 301, :queued, "Ask for the permission again on the next tap."},
    {"lea", "acme/billing", 503, :closed, ""},
    {"sam", "acme/mobile", 303, :closed, ""},
    {"amara", "acme/docs", 601, :undone, ""}
  ]

  # Comments people write on work items, by the ticket.
  @thread [
    {"acme/shop", 101, "dana", "The voucher fix should land before the weekend sale."},
    {"acme/shop", 106, "mirek", "The banner may go with the theme rework instead."},
    {"acme/api", 201, "priya", "The pool was busy; the run waits for the next machine."}
  ]

  @doc false
  # fill/2 makes the factory part in `main`, Dana's scope of Main, and in `second`, hers
  # of Shop ops, or nil where the edition allows one workspace. Prints its summary lines.
  @spec fill(Scope.t(), Scope.t() | nil) :: :ok
  def fill(%Scope{} = main, second) do
    admin = signed_in(main)
    {tracker, key} = adapter!(admin, "Tracker", tracker_source())
    connection = connect!(main, tracker, key)

    list_collections!(key, connection, @host, for({path, _} <- @repositories, do: path))
    repositories = assign!(main, second, connection)
    tickets!(key, @tickets, @host, @comments)

    {:ok, 1} =
      Collections.set_collection_backlog(
        main,
        connection,
        Map.fetch!(repositories, @backlog_off).id,
        false
      )

    work_items!(main)

    {helpdesk, desk_key} = adapter!(admin, "Helpdesk", helpdesk_source())
    desk = connect!(main, helpdesk, desk_key)
    list_collections!(desk_key, desk, @helpdesk_host, @queues)
    assign_queues!(main, desk)
    tickets!(desk_key, @incidents, @helpdesk_host, @incident_comments)

    summary(tracker)
    summary(helpdesk)
  end

  # Dana's scope as a sign-in a minute ago leaves it: what an instance admin's change of
  # an adapter, or its code, asks for.
  defp signed_in(%Scope{user: user} = scope),
    do: %{scope | user: %{user | authenticated_at: DateTime.utc_now(:second)}}

  ## The adapter

  # The adapter `name`, its enrolment code, the key it enrols with it and its
  # declaration, with `source` as its description's source role. Returns the adapter,
  # and its key with the key's secret, which signs the connect return.
  defp adapter!(admin, name, source) do
    {:ok, adapter} = Adapters.create_adapter(admin, %{"name" => name})
    {:ok, _row, code} = Adapters.create_code(admin, adapter)
    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    program = String.downcase(name)
    {:ok, key} = AccessKeys.enrol(enrolment(code, public, secret, program))

    {:ok, declaration} =
      AdapterWire.declaration(Jason.encode!(declaration(name, program, source)))

    {:ok, adapter} = Adapters.declare(key_scope(key), declaration)

    {adapter, {key, secret}}
  end

  # The request the adapter enrols with: its code, its public key and the proof under it.
  defp enrolment(code, public, secret, name) do
    code = Enrolment.issued_code(code, Apiary.SigningKey.fingerprint())
    public = Ed25519.encode(public)
    now = System.os_time(:second)
    message = SignedMessage.enrolment(code, public, name, now)
    proof = :crypto.sign(:eddsa, :none, message, [secret, :ed25519])

    {:ok, request} =
      Enrolment.decode(
        Jason.encode!(%{
          "version" => 1,
          "code" => code,
          "name" => name,
          "public_key" => public,
          "timestamp" => now,
          "proof" => Ed25519.encode(proof)
        })
      )

    request
  end

  defp declaration(title, program, source) do
    %{
      "version" => 1,
      "time" => time(DateTime.utc_now()),
      "connect_url" => "https://#{program}.example.com/connect",
      "sync" => %{"default_interval" => 900, "minimum_interval" => 300, "sends_changes" => true},
      "description" => %{
        "version" => 1,
        "name" => program,
        "title" => title,
        "program_version" => "0.4.0",
        "settings" => %{"type" => "object"},
        "roles" => %{"source" => source}
      }
    }
  end

  defp tracker_source do
    %{
      "description" => "Reads the open tickets of Tracker repositories.",
      "program" => "tracker-adapter",
      "setup" => %{
        "command" => "tracker-adapter setup",
        "help" => "Asks for the address of the Tracker site and registers the adapter."
      },
      "start" => "tracker-adapter serve --secret-file /etc/tracker-adapter/secret",
      "connect" => "Tracker asks you to sign in and to choose the repositories it reads.",
      "access" =>
        "In Tracker, open Settings, then Adapters, to change which repositories it reads.",
      "disconnect" => "In Tracker, open Settings, then Adapters, and remove the adapter.",
      "item_noun" => %{"one" => "ticket", "other" => "tickets"},
      "collection_noun" => %{"one" => "repository", "other" => "repositories"}
    }
  end

  defp helpdesk_source do
    %{
      "description" => "Reads the open incidents of Helpdesk queues.",
      "program" => "helpdesk-adapter",
      "setup" => %{
        "command" => "helpdesk-adapter setup",
        "help" => "Asks for the address of the Helpdesk site and registers the adapter."
      },
      "start" => "helpdesk-adapter serve --secret-file /etc/helpdesk-adapter/secret",
      "connect" => "Helpdesk asks you to sign in and to choose the queues it reads.",
      "access" => "In Helpdesk, open Settings, then Adapters, to change which queues it reads.",
      "disconnect" => "In Helpdesk, open Settings, then Adapters, and remove the adapter.",
      "item_noun" => %{"one" => "incident", "other" => "incidents"},
      "collection_noun" => %{"one" => "queue", "other" => "queues"}
    }
  end

  # The scope of the adapter's key as a verified request carries it, after the request
  # is recorded as a use of the key, as the adapter's requests are.
  defp key_scope({key, _secret}), do: key_scope(key)

  defp key_scope(key) do
    :ok = AccessKeys.touch_delivery(key, %{})
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)
    Scope.for_access_key(verified)
  end

  ## The connection

  # Dana presses Install, and comes back with the adapter's return, which says it linked.
  defp connect!(main, adapter, {_key, secret}) do
    {:ok, _url, {connection_id, nonce}} = Adapters.connect(main, adapter)
    token = return_token(secret, connection_id, nonce)
    {:ok, :linked} = Connections.complete_return(main, connection_id, token, nonce)
    Map.fetch!(Connections.live_by_adapter(main), adapter.id)
  end

  # The return the adapter hands back for the connection's pass, signed with its key.
  defp return_token(secret, connection_id, nonce) do
    payload =
      Jason.encode!(%{
        "version" => 1,
        "connection_id" => connection_id,
        "nonce" => nonce,
        "outcome" => "linked",
        "expires_at" => time(DateTime.add(DateTime.utc_now(), 240, :second))
      })

    signature =
      :crypto.sign(:eddsa, :none, SignedMessage.connect_return(payload), [secret, :ed25519])

    Ed25519.encode(payload) <> "." <> Ed25519.encode(signature)
  end

  ## The repositories

  # The adapter's listing of the collections it reaches, `paths`, in one part. A path on
  # the code host is a repository's target; a queue of `@queues` has none.
  defp list_collections!(key, connection, host, paths) do
    now = DateTime.utc_now()

    body = %{
      "version" => 1,
      "time" => time(now),
      "connection_id" => connection.public_id,
      "collections" =>
        for path <- paths do
          collection = %{"ref" => path, "url" => "#{host}/#{path}", "title" => path}

          if path in @queues,
            do: collection,
            else: Map.put(collection, "target", %{"system" => @code_host, "path" => path})
        end,
      "listing" => %{
        "id" => "collections-#{System.os_time(:second)}",
        "part" => 1,
        "started_at" => time(DateTime.add(now, -5, :second)),
        "complete" => true
      }
    }

    {:ok, decoded} = body |> Jason.encode!() |> AdapterWire.decode()
    {:ok, listing} = AdapterWire.listing(decoded)
    {:ok, :accepted} = Collections.post_listing(key_scope(key), listing)
  end

  # Dana assigns each repository as the Integrations page would: to Main, to Shop ops (or
  # Main, where the edition allows one workspace), or to none. With one workspace the
  # listing assigned each to Main already, so the assign to none takes the last one out.
  # Returns the repositories as the page lists them, by their title.
  defp assign!(main, second, connection) do
    rows = Map.new(Collections.list_collections(main, connection), &{&1.name, &1})

    workspaces = %{
      main: main.workspace,
      second: (second || main).workspace,
      none: nil
    }

    @repositories
    |> Enum.group_by(&elem(&1, 1), &Map.fetch!(rows, elem(&1, 0)).id)
    |> Enum.each(fn {where, ids} ->
      {:ok, _changed} =
        Collections.assign_collections(main, connection, ids, Map.fetch!(workspaces, where))
    end)

    rows
  end

  # Dana assigns the queues as the Integrations page would: to Support where the
  # edition allows more than one workspace, else to Main.
  defp assign_queues!(main, connection) do
    ids =
      for %{name: name, id: id} <- Collections.list_collections(main, connection),
          name in @queues,
          do: id

    {:ok, _changed} = Collections.assign_collections(main, connection, ids, support!(main))
  end

  # The workspace Support, found or made by Dana as the page that adds a workspace makes
  # it, where the edition's limit allows more than one workspace; Main where it allows
  # one, or where Support would pass the limit.
  defp support!(%Scope{} = main) do
    if Apiary.Edition.limits().workspaces == 1 do
      main.workspace
    else
      case Organisations.resolve_scope(Scope.for_user(main.user), "acme", "support") do
        {:ok, %Scope{workspace: workspace}} -> workspace
        :error -> make_support(main)
      end
    end
  end

  defp make_support(main) do
    case Organisations.create_workspace(main, %{
           "name" => "Support",
           "slug" => "support",
           "domain" => "software"
         }) do
      {:ok, workspace} ->
        workspace

      {:error, :limit} ->
        Shell.info(
          "The edition allows acme no more workspaces: support is not made; its queues go to main"
        )

        main.workspace
    end
  end

  ## The tickets

  # Each collection's tickets of `tickets`, at `host`, as a complete listing of them, then
  # each ticket's comments, from `pool`.
  defp tickets!(key, tickets, host, pool) do
    now = DateTime.utc_now()

    for {path, tickets} <- Enum.group_by(tickets, &elem(&1, 0)) do
      body = %{
        "version" => 1,
        "time" => time(now),
        "collection_ref" => path,
        "items" => Enum.map(tickets, &item(&1, host, now)),
        "listing" => %{
          "id" => "tickets-#{path}-#{System.os_time(:second)}",
          "part" => 1,
          "started_at" => time(DateTime.add(now, -5, :second)),
          "complete" => true
        }
      }

      {:ok, items} = SourceWire.items(Jason.encode!(body))
      {:ok, :accepted} = Sources.post_items(key_scope(key), items)
    end

    for ticket <- tickets, elem(ticket, 7) > 0 do
      body = %{
        "version" => 1,
        "time" => time(now),
        "item_ref" => ref(ticket),
        "comments" => comments(ticket, host, pool, now)
      }

      {:ok, comments} = SourceWire.comments(Jason.encode!(body))
      {:ok, :accepted} = Sources.post_comments(key_scope(key), comments)
    end
  end

  defp item(
         {path, number, type, title, labels, filer, state, count, _days, line} = ticket,
         host,
         now
       ) do
    filed = filed_at(ticket, now)
    {name, kind} = Map.fetch!(@filers, filer)

    %{
      "ref" => ref(ticket),
      "key" => "##{number}",
      "type" => type,
      "url" => "#{host}/#{path}/#{segment(type)}/#{number}",
      "title" => title,
      "body" => body(type, line, path),
      "body_format" => "markdown",
      "filed_by" => %{"name" => name, "kind" => kind},
      "labels" => labels,
      "state" => state,
      "state_reason" => if(state == "closed", do: "completed"),
      "comment_count" => count,
      "created_at" => time(filed),
      "updated_at" => time(updated(filed, now, count))
    }
  end

  # A ticket changes last with its last comment, an hour apart from its filing for each.
  defp updated(filed, now, count),
    do: Enum.min([DateTime.add(filed, (count + 1) * 3600, :second), now], DateTime)

  # The part of a ticket's address at its source that comes before its number.
  defp segment("incident"), do: "incidents"
  defp segment(_type), do: "tickets"

  defp ref({path, number, _type, _title, _labels, _filer, _state, _count, _days, _line}),
    do: "#{path}##{number}"

  # When the ticket was filed: its days ago, and ten minutes more for each number, so that
  # no two tickets are filed at the same time.
  defp filed_at(
         {_path, number, _type, _title, _labels, _filer, _state, _count, days, _line},
         now
       ),
       do: DateTime.add(now, -days * 86_400 - number * 600, :second)

  defp body("bug", line, path) do
    """
    #{line}

    ## Steps

    1. Open the staging build of `#{path}`.
    2. Repeat what the title says.
    3. Compare the result with production.

    ## Expected

    The same result as in production, and no error in the log.
    """
  end

  defp body("feature", line, _path) do
    """
    #{line}

    ## Done when

    - [ ] The change is behind a flag, off by default.
    - [ ] The help centre describes it.
    - [ ] Support has seen it on staging.
    """
  end

  defp body("incident", line, _path) do
    """
    #{line}

    ## Impact

    - Customers affected since the first report
    - Workaround: none yet
    """
  end

  defp body("task", line, path) do
    """
    #{line}

    - Owner: the team of `#{path}`
    - See the [runbook](https://docs.example.com/runbooks) for the steps.
    """
  end

  # The ticket's comments, each from the pool in turn, an hour apart after its filing.
  defp comments(
         {path, number, type, _title, _labels, _filer, _state, count, _days, _line} = ticket,
         host,
         pool,
         now
       ) do
    filed = filed_at(ticket, now)

    for n <- 1..count do
      {author, text} = Enum.at(pool, rem(number + n, length(pool)))
      {name, kind} = Map.fetch!(@filers, author)
      at = Enum.min([DateTime.add(filed, n * 3600, :second), now], DateTime)

      %{
        "ref" => "#{ref(ticket)}-#{n}",
        "url" => "#{host}/#{path}/#{segment(type)}/#{number}#comment-#{n}",
        "author" => %{"name" => name, "kind" => kind},
        "body" => text,
        "body_format" => "markdown",
        "created_at" => time(at),
        "updated_at" => time(at)
      }
    end
  end

  ## The work items

  defp work_items!(main) do
    made =
      for {person, path, number, what, instruction} <- @work_items, into: %{} do
        scope = person_scope!(main, person)
        title = title_of(path, number)

        [%{id: ticket_id}] =
          Backlog.list_tickets(scope, %{view: :open, search: title}).rows
          |> Enum.filter(&(&1.title == title))

        {:ok, work_item} =
          WorkItems.take_in(scope, ticket_id, %{"first_instruction" => instruction})

        {{path, number}, {scope, work_item, what}}
      end

    for {_ticket, {scope, work_item, what}} <- made, do: move!(scope, work_item, what)

    for {path, number, person, text} <- @thread do
      {_scope, work_item, _what} = Map.fetch!(made, {path, number})
      {:ok, _comment} = WorkItems.comment(person_scope!(main, person), work_item, text)
    end
  end

  defp move!(_scope, _work_item, :queued), do: :ok

  defp move!(scope, work_item, :closed),
    do: {:ok, _work_item} = WorkItems.close(scope, current(scope, work_item))

  defp move!(scope, work_item, :undone),
    do: {:ok, _work_item} = WorkItems.undo(scope, current(scope, work_item))

  defp current(scope, %WorkItem{public_id: id}), do: WorkItems.get_by_public_id(scope, id)

  defp title_of(path, number) do
    Enum.find_value(@tickets, fn
      {^path, ^number, _type, title, _labels, _filer, _state, _count, _days, _line} -> title
      _other -> nil
    end)
  end

  # The person's scope of the workspace of `main`, as their page has it.
  defp person_scope!(%Scope{workspace: workspace}, name) do
    user = Accounts.get_user_by_email("#{name}@example.com")

    case Organisations.resolve_scope(Scope.for_user(user), "acme", workspace.slug) do
      {:ok, scope} -> Scope.put_origin(scope, %{worker: "demo"})
      :error -> Shell.raise!("#{name}@example.com does not reach acme/#{workspace.slug}")
    end
  end

  ## The summary

  # The adapter's lines: its collections by workspace, its tickets by state and the work
  # items of them by state, each in the adapter's words.
  defp summary(adapter) do
    collections =
      Repo.all(
        from c in Collection,
          left_join: w in assoc(c, :workspace),
          where: c.adapter_id == ^adapter.id and is_nil(c.ended_at),
          group_by: w.slug,
          order_by: w.slug,
          select: {coalesce(w.slug, "unassigned"), count()}
      )

    tickets =
      Repo.all(
        from i in Item,
          where: i.adapter_id == ^adapter.id,
          group_by: i.state,
          order_by: i.state,
          select: {i.state, count()}
      )

    work_items =
      Repo.all(
        from w in WorkItem,
          where: w.adapter_id == ^adapter.id,
          group_by: w.state,
          order_by: w.state,
          select: {w.state, count()}
      )

    %{other: collections_word} = Adapters.collection_noun(adapter)
    %{other: items_word} = Adapters.item_noun(adapter)

    Shell.info("""
    Factory: #{adapter.name}, #{total(collections)} #{collections_word}, \
    #{total(tickets)} #{items_word}, #{total(work_items)} work items
      #{collections_word}: #{format(collections)}
      #{items_word}: #{format(tickets)}
      work items: #{format(work_items)}\
    """)
  end

  defp total(pairs), do: pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp format([]), do: "none"
  defp format(pairs), do: Enum.map_join(pairs, ", ", fn {name, count} -> "#{name} #{count}" end)

  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
