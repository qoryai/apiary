defmodule ApiaryWeb.SupportTest do
  @moduledoc """
  "Contact support" (`ApiaryWeb.Support`): a link to the support address where one is
  set, `mailto:` for an email address, plain text where none is; as a component, as rich
  text inside a translated sentence, and as plain text.
  """
  # Not async: hiding the instance's organisation acts on the row every test shares.
  use Apiary.DataCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import ApiaryWeb.RichText

  use Gettext, backend: ApiaryWeb.Gettext

  alias ApiaryWeb.Support

  doctest ApiaryWeb.Support

  # Without LiveView's marker of a rendered root, which says nothing of the words.
  defp html(rendered), do: rendered |> rendered_to_string() |> String.replace(" phx-r", "")

  defp contact(attrs) do
    assigns = Map.new(attrs)

    html(~H"""
    <Support.contact {assigns} />
    """)
  end

  describe "contact/1" do
    test "links an https address as it is" do
      assert contact(address: "https://help.example.com", id: "support") ==
               ~s(<a id="support" href="https://help.example.com" class="q-link" rel="noopener noreferrer">Contact support</a>)
    end

    test "links an email address with mailto:, inside a sentence in lower case" do
      assert contact(address: "support@example.com", mid_sentence: true) ==
               ~s(<a href="mailto:support@example.com" class="q-link" rel="noopener noreferrer">contact support</a>)
    end

    test "shows plain text with no address" do
      assert contact(address: nil) == ~s(<span>Contact support</span>)
      assert contact(address: nil, mid_sentence: true) == ~s(<span>contact support</span>)
    end

    test "plain/1 has the address after the words, and no link" do
      assert Support.plain(address: "support@example.com") ==
               "Contact support at support@example.com"

      assert Support.plain(address: "https://help.example.com", mid_sentence: true) ==
               "contact support at https://help.example.com"

      assert Support.plain(address: nil) == "Contact support"
    end

    test "takes other words from its inner block" do
      assigns = %{}

      assert html(~H"""
             <Support.contact address="support@example.com">Write to support</Support.contact>
             """) =~
               ~s(href="mailto:support@example.com" class="q-link" rel="noopener noreferrer">Write to support</a>)
    end
  end

  describe "with the address saved" do
    setup do
      Application.put_env(:apiary, :support_address, nil)
      on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)
      Apiary.EditionKit.hide_instance_organisation()
      %{scope: scope} = Apiary.OrganisationsFixtures.sign_up_fixture()
      %{scope: scope}
    end

    test "each form reads it, and shows plain text before it is saved", %{scope: scope} do
      assert contact([]) == ~s(<span>Contact support</span>)
      assert Support.rich() == "Contact support"
      assert Support.text() == "Contact support."

      {:ok, _address} =
        Apiary.SupportAddress.save(scope, %{"support_address" => "support@example.com"})

      assert contact([]) =~ ~s(href="mailto:support@example.com")
      assert Support.rich() == {:href, "mailto:support@example.com", "Contact support"}
      assert Support.text() == "Contact support at support@example.com."
    end

    test "SUPPORT_ADDRESS wins over it", %{scope: scope} do
      {:ok, _address} =
        Apiary.SupportAddress.save(scope, %{"support_address" => "support@example.com"})

      Application.put_env(:apiary, :support_address, "https://help.example.com")

      assert Support.rich(mid_sentence: true) ==
               {:href, "https://help.example.com", "contact support"}
    end
  end

  describe "stored_line/2, for an escalation's stored fix line" do
    setup do
      Application.put_env(:apiary, :support_address, nil)
      on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)
      Apiary.EditionKit.hide_instance_organisation()
      %{scope: scope} = Apiary.OrganisationsFixtures.sign_up_fixture()
      %{scope: scope}
    end

    defp shown(line) do
      assigns = %{text: Support.stored_line(line)}
      html(~H"<.rich text={@text} />")
    end

    test "links Contact support where an address is set", %{scope: scope} do
      {:ok, _address} =
        Apiary.SupportAddress.save(scope, %{"support_address" => "https://help.example.com"})

      assert shown("Contact support with run r-42.") ==
               ~s(<a href="https://help.example.com" class="q-link">Contact support</a> with run r-42.)

      assert shown("Contact support with work item #7.") ==
               ~s(<a href="https://help.example.com" class="q-link">Contact support</a> with work item #7.)
    end

    test "shows the stored line as plain text where none is" do
      assert shown("Contact support with run r-42.") == "Contact support with run r-42."
    end

    test "leaves a line that does not start with Contact support as it is", %{scope: scope} do
      {:ok, _address} =
        Apiary.SupportAddress.save(scope, %{"support_address" => "support@example.com"})

      line = "Owners and admins of Acme connect one in Organisation settings › Integrations."
      assert Support.stored_line(line) == line
      assert shown(line) == line
    end
  end

  describe "rich/1 in a translated sentence" do
    # A sentence of the pattern `ApiaryWeb.Support` documents: one msgid, the words a
    # binding.
    defp sentence(address) do
      assigns = %{
        text:
          rich_gettext("%{contact_support} with run %{run}.",
            contact_support: Support.rich(address: address),
            run: {:m, "r-42"}
          )
      }

      html(~H"<.rich text={@text} />")
    end

    test "is a link inside the sentence where an address is set" do
      assert sentence("support@example.com") ==
               ~s(<a href="mailto:support@example.com" class="q-link">Contact support</a> with run <span class="font-mono text-[12px]">r-42</span>.)
    end

    test "is the words alone where none is" do
      assert sentence(nil) ==
               ~s(Contact support with run <span class="font-mono text-[12px]">r-42</span>.)
    end
  end

  describe "the harness read and save texts" do
    setup do
      on_exit(fn -> Application.put_env(:apiary, :support_address, nil) end)
      :ok
    end

    @source %{label: "acme/harness", kind: :assigned}
    @call %{adapter: "GitHub", code: nil, seconds: 10}
    @names %{
      source: "https://git.example.com/acme/harness.git",
      organisation: "Acme",
      workspace: "Web",
      host: "git.example.com",
      port: 443,
      seconds: 10
    }

    # Every text of `ApiaryWeb.HarnessComponents` that sends the reader to support.
    defp support_texts do
      reads =
        [
          {:unreadable, :address},
          {:unreadable, :path, "../x"},
          {:unreadable, :version, "v 9"},
          {:no_version, "v9"},
          :exited
        ] ++
          for(
            cause <- [:timeout, :unreachable, :no_address, :unauthorized, :invalid_answer],
            do: {:call, Map.put(@call, :cause, cause)}
          )

      Enum.map(reads, &ApiaryWeb.HarnessComponents.read_words(&1, @source, "Acme")) ++
        [
          ApiaryWeb.HarnessComponents.refusal_words(
            {:walk, %{failure: :not_allowed}},
            @source,
            "main",
            "Acme"
          ),
          ApiaryWeb.HarnessComponents.public_read_words(:source_unreachable, @names),
          ApiaryWeb.HarnessComponents.public_read_words(:host_not_allowed, @names),
          ApiaryWeb.StagesLive.Words.read_failed(
            ApiaryWeb.HarnessComponents.read_words(:exited, @source, "Acme"),
            nil
          )
        ]
    end

    defp shown_text(text) do
      assigns = %{text: text}
      html(~H"<.rich text={@text} />")
    end

    test "link Contact support where an address is set, with the words unchanged" do
      Application.put_env(:apiary, :support_address, nil)
      plain = support_texts()

      Application.put_env(:apiary, :support_address, "support@example.com")
      linked = support_texts()

      assert length(linked) == 14

      for {text, words} <- Enum.zip(linked, plain) do
        shown = shown_text(text)

        assert shown =~
                 ~r{<a href="mailto:support@example.com" class="q-link">[Cc]ontact support</a>}

        assert plain_text(text) == plain_text(words)
      end
    end

    test "show Contact support as plain text where none is" do
      Application.put_env(:apiary, :support_address, nil)

      for text <- support_texts() do
        shown = shown_text(text)
        refute shown =~ "<a "
        assert shown =~ ~r/[Cc]ontact support/
      end
    end
  end
end
