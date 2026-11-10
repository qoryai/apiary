defmodule Apiary.SupportAddressTest do
  @moduledoc """
  The support address (`Apiary.SupportAddress`): what an address may be, the variable
  `SUPPORT_ADDRESS` that wins over the address saved, who may save it, the instance's
  trail, and each node's copy (`Apiary.SupportAddress.Cache`).
  """
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the variable's value and the cache's copy are the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.SupportAddress
  alias Apiary.SupportAddress.Cache

  setup do
    put_env(nil)
    Apiary.EditionKit.hide_instance_organisation()
    %{scope: scope} = sign_up_fixture()
    assert Apiary.Access.instance_admin?(scope)
    %{scope: scope}
  end

  # Sets the variable's value as `boot!/0` keeps it, for one test.
  defp put_env(address) do
    before = Application.fetch_env(:apiary, :support_address)
    Application.put_env(:apiary, :support_address, address)

    on_exit(fn ->
      case before do
        {:ok, value} -> Application.put_env(:apiary, :support_address, value)
        :error -> Application.delete_env(:apiary, :support_address)
      end
    end)
  end

  defp save(scope, address), do: SupportAddress.save(scope, %{"support_address" => address})

  defp entries,
    do:
      Repo.all(
        from e in Entry,
          where: e.action == "instance.support_save",
          order_by: [asc: e.inserted_at, asc: e.id]
      )

  describe "parse/1" do
    test "takes an https address or an email address, trimmed" do
      assert SupportAddress.parse(" https://help.example.com/contact?from=app ") ==
               {:ok, "https://help.example.com/contact?from=app"}

      assert SupportAddress.parse("support@example.com") == {:ok, "support@example.com"}

      assert SupportAddress.parse("help+qory@mail.example.co.uk") ==
               {:ok, "help+qory@mail.example.co.uk"}
    end

    test "takes nil and a blank value as none" do
      assert SupportAddress.parse(nil) == {:ok, nil}
      assert SupportAddress.parse("  ") == {:ok, nil}
    end

    test "refuses anything else" do
      for value <- [
            "http://help.example.com",
            "https://",
            "https://user:secret@help.example.com",
            "https://help.example.com/a page",
            "help.example.com",
            "support@example",
            "support@@example.com",
            "javascript:alert(1)",
            "mailto:support@example.com",
            "a@b.c?cc=evil%40x.com",
            "a@b.c?subject=hi&body=x",
            "a@b.c?bcc=e%40x.com%0D%0AX",
            "a@b.c#x",
            "a@b.c?x",
            "a@b.c?cc=x",
            "support%40x@example.com",
            ~s("support"@example.com),
            ~s("<x>"@b.c),
            "<x>@b.c",
            "<support@example.com>",
            "support@example.com>",
            "Support <support@example.com>",
            "support@exa_mple.com",
            String.duplicate("a", 255) <> "@example.com",
            "https://" <> String.duplicate("a", 2050) <> ".example.com"
          ] do
        assert {:error, reason} = SupportAddress.parse(value), value
        assert is_binary(reason)
      end
    end
  end

  describe "with no address" do
    test "there is none, and no link" do
      assert SupportAddress.get() == nil
      assert SupportAddress.href() == nil
      assert SupportAddress.source() == :none
    end
  end

  describe "an address saved" do
    test "is the address, with its link", %{scope: scope} do
      assert {:ok, "support@example.com"} = save(scope, " support@example.com ")
      assert SupportAddress.get() == "support@example.com"
      assert SupportAddress.href() == "mailto:support@example.com"
      assert SupportAddress.source() == :saved

      assert {:ok, "https://help.example.com"} = save(scope, "https://help.example.com")
      assert SupportAddress.href() == "https://help.example.com"
    end

    test "saved empty is none again", %{scope: scope} do
      {:ok, _address} = save(scope, "support@example.com")
      assert {:ok, nil} = save(scope, "")
      assert SupportAddress.get() == nil
    end

    test "is refused with the field's error, which starts with the fix", %{scope: scope} do
      assert {:error, changeset} = save(scope, "help.example.com")

      assert errors_on(changeset).support_address == [
               "Enter an https address, such as https://help.example.com, or an email address, such as support@example.com."
             ]

      assert SupportAddress.get() == nil
    end

    test "is an instance.support_save entry in the instance's trail, by the admin, with the address before and after",
         %{scope: scope} do
      assert {:ok, "support@example.com"} = save(scope, "support@example.com")
      assert [entry] = entries()
      assert {entry.actor_kind, entry.actor_id} == {:person, scope.user.id}
      assert entry.organisation_id == Apiary.Edition.instance_organisation_id()
      assert {entry.subject_kind, entry.subject_id} == {"organisation", entry.organisation_id}

      # The trail keeps no email address: an email address is "email".
      assert {entry.before, entry.after} ==
               {%{"support_address" => nil}, %{"support_address" => "email"}}

      # The same address again changes nothing, and so records nothing.
      assert {:ok, "support@example.com"} = save(scope, " support@example.com ")
      assert [_one] = entries()

      # Another email address is a change, kept the same way.
      assert {:ok, "help@example.com"} = save(scope, "help@example.com")
      assert [_, other] = entries()

      assert {other.before, other.after} ==
               {%{"support_address" => "email"}, %{"support_address" => "email"}}

      assert {:ok, "https://help.example.com"} = save(scope, "https://help.example.com")
      assert {:ok, nil} = save(scope, "")
      assert [_, _, linked, emptied] = entries()

      assert {linked.before, linked.after} ==
               {%{"support_address" => "email"},
                %{"support_address" => "https://help.example.com"}}

      assert {emptied.before, emptied.after} ==
               {%{"support_address" => "https://help.example.com"}, %{"support_address" => nil}}

      # An https address is kept without its query string or fragment.
      assert {:ok, "https://help.example.com/contact?from=app#form"} =
               save(scope, "https://help.example.com/contact?from=app#form")

      assert [_, _, _, _, queried] = entries()

      assert queried.after == %{"support_address" => "https://help.example.com/contact"}
    end

    test "is not saved by anyone but an instance admin" do
      %{scope: other} = sign_up_fixture()
      refute Apiary.Access.instance_admin?(other)

      assert save(other, "support@example.com") == {:error, :not_found}
      assert save(nil, "support@example.com") == {:error, :not_found}
      assert SupportAddress.get() == nil
      assert entries() == []
    end
  end

  describe "SUPPORT_ADDRESS" do
    test "wins over the address saved, which a save does not change", %{scope: scope} do
      {:ok, _address} = save(scope, "support@example.com")
      put_env("https://help.example.com")

      assert SupportAddress.get() == "https://help.example.com"
      assert SupportAddress.source() == :env
      assert SupportAddress.stored() == "support@example.com"
      assert save(scope, "other@example.com") == {:error, :env}
      assert SupportAddress.stored() == "support@example.com"
    end

    test "is checked at boot, and kept as nil where it is not set or blank" do
      on_exit(fn -> Application.delete_env(:apiary, :support_address_setting) end)

      Application.put_env(:apiary, :support_address_setting, " support@example.com ")
      assert SupportAddress.boot!() == "support@example.com"
      assert SupportAddress.env() == "support@example.com"

      Application.put_env(:apiary, :support_address_setting, "  ")
      assert SupportAddress.boot!() == nil
      assert SupportAddress.env() == nil

      Application.put_env(:apiary, :support_address_setting, "help.example.com")

      assert_raise ArgumentError,
                   ~r/^Set SUPPORT_ADDRESS to an https address or an email address, or leave it unset/,
                   &SupportAddress.boot!/0
    end
  end

  describe "Apiary.SupportAddress.Cache, each node's copy" do
    test "holds what the database has, reads it again on every save, and leaves when it stops",
         %{scope: scope} do
      assert Cache.cached() == :error
      start_supervised!(Cache)
      assert Cache.cached() == {:ok, nil}

      assert {:ok, "support@example.com"} = save(scope, "support@example.com")
      eventually(fn -> assert Cache.cached() == {:ok, "support@example.com"} end)
      assert SupportAddress.get() == "support@example.com"

      assert {:ok, nil} = save(scope, "")
      eventually(fn -> assert Cache.cached() == {:ok, nil} end)
      assert SupportAddress.get() == nil

      stop_supervised!(Cache)
      assert Cache.cached() == :error
    end
  end

  # Asserts `fun` within a few seconds: the cache reads the row again once the broadcast
  # reaches it.
  defp eventually(fun, tries \\ 100) do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if tries == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(20)
      eventually(fun, tries - 1)
  end
end
