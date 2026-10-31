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
end
