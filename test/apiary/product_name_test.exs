defmodule Apiary.ProductNameTest do
  @moduledoc """
  The product's name an instance admin sets (`Apiary.ProductName`): the name every page
  and email shows, the edition's where none is set; the rules a name given keeps, an
  organisation's name's; "Qory Apiary" typed in, which is no name; who may set it, and the
  instance's trail; "Powered by Qory Apiary"; and each node's copy
  (`Apiary.ProductName.Cache`).
  """
  # Not async: hiding the instance's organisation acts on the row every test shares, and
  # the cache's copy is the whole node's.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.ProductName
  alias Apiary.ProductName.Cache

  setup do
    Apiary.EditionKit.hide_instance_organisation()
    %{scope: scope} = sign_up_fixture()
    assert Apiary.Access.instance_admin?(scope)
    %{scope: scope}
  end

  defp rename(scope, name), do: ProductName.rename(scope, %{"product_name" => name})

  defp entries,
    do:
      Repo.all(
        from e in Entry, where: e.action == "instance.rename", order_by: [asc: e.inserted_at]
      )

  describe "with no name set" do
    test "every page and email shows the edition's, Qory Apiary in the core's" do
      assert ProductName.get() == nil
      assert ProductName.default() == ApiaryWeb.Edition.product_name()
      assert ProductName.default() == "Qory Apiary"
      assert ProductName.name() == "Qory Apiary"
      refute ProductName.powered_by?()
    end

    test "the form is empty" do
      assert Ecto.Changeset.get_field(ProductName.change(), :product_name) == nil
    end
  end

  describe "rename/2, for an instance admin" do
    test "sets the name every page and email shows, and Powered by beside it", %{scope: scope} do
      assert {:ok, "Acme Agents"} = rename(scope, "Acme Agents")

      assert ProductName.get() == "Acme Agents"
      assert ProductName.name() == "Acme Agents"
      assert ProductName.powered_by?()
      assert Ecto.Changeset.get_field(ProductName.change(), :product_name) == "Acme Agents"

      %{rows: [[updated_by]]} =
        Repo.query!("SELECT updated_by_id FROM instance_settings WHERE id")

      assert Ecto.UUID.cast!(updated_by) == scope.user.id
    end

    test "takes spaces off either end; empty, or spaces only, is no name", %{scope: scope} do
      assert {:ok, "Acme Agents"} = rename(scope, "  Acme Agents \n")
      assert ProductName.get() == "Acme Agents"

      assert {:ok, nil} = rename(scope, "   ")
      assert ProductName.get() == nil
      assert ProductName.name() == "Qory Apiary"
      refute ProductName.powered_by?()

      assert {:ok, "Acme Agents"} = rename(scope, "Acme Agents")
      assert {:ok, nil} = rename(scope, "")
      assert ProductName.get() == nil
    end

    test "stores Qory Apiary typed in as no name where the edition's name is Qory Apiary",
         %{scope: scope} do
      assert {:ok, "Acme Agents"} = rename(scope, "Acme Agents")

      assert {:ok, nil} = rename(scope, "Qory Apiary")
      assert ProductName.get() == nil
      %{rows: [[nil]]} = Repo.query!("SELECT product_name FROM instance_settings WHERE id")

      assert {:ok, nil} = rename(scope, "  Qory Apiary  ")
      refute ProductName.powered_by?()
    end

    test "stores Qory Apiary as typed where the edition names the product otherwise, with no Powered by" do
      changeset =
        ProductName.Row.changeset(
          %ProductName.Row{},
          %{"product_name" => "Qory Apiary"},
          "Another Product"
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :product_name) == "Qory Apiary"
      refute ProductName.powered_by?("Qory Apiary")
    end

    test "allows Qory inside a name", %{scope: scope} do
      assert {:ok, "Qory Agents"} = rename(scope, "Qory Agents")
      assert ProductName.powered_by?()
      assert {:ok, "Qory Apiary for Acme"} = rename(scope, "Qory Apiary for Acme")
    end

    test "keeps the rules of an organisation's name, 120 characters included", %{scope: scope} do
      for {name, message} <- [
            {String.duplicate("a", 121), "should be at most 120 character(s)"},
            {"Acme\u0007Agents", "must not contain control characters"},
            {"Acme​Agents", "must not contain invisible characters"},
            {"Acme Agents‍", "must not start or end with a joining character"},
            {"https://acme.example",
             "must not contain a web address; a name like acme.io is fine"},
            {"www.acme.example", "must not contain a web address; a name like acme.io is fine"},
            {~s(Acme "Agents"), "must not contain quotation marks"},
            {"Acme «Agents»", "must not contain quotation marks"}
          ] do
        assert {:error, changeset} = rename(scope, name)
        assert errors_on(changeset) == %{product_name: [message]}, inspect(name)
      end

      assert ProductName.get() == nil
      assert entries() == []

      # 120 characters are a name, and so are a bare domain and an apostrophe.
      long = String.duplicate("a", 120)
      assert {:ok, ^long} = rename(scope, long)
      assert {:ok, "acme.io"} = rename(scope, "acme.io")
      assert {:ok, "Dana’s Agents"} = rename(scope, "Dana’s Agents")
    end

    test "is an instance.rename entry in the instance's trail, by the admin, with the name before and after",
         %{scope: scope} do
      assert {:ok, "Acme Agents"} = rename(scope, "Acme Agents")
      assert [entry] = entries()
      assert {entry.actor_kind, entry.actor_id} == {:person, scope.user.id}
      assert entry.organisation_id == Apiary.Edition.instance_organisation_id()
      assert {entry.subject_kind, entry.subject_id} == {"organisation", entry.organisation_id}
      assert {entry.before, entry.after} == {%{"name" => nil}, %{"name" => "Acme Agents"}}

      # The same name again changes nothing, and so records nothing.
      assert {:ok, "Acme Agents"} = rename(scope, " Acme Agents ")
      assert [_one] = entries()

      assert {:ok, nil} = rename(scope, "")
      assert [_, emptied] = entries()
      assert {emptied.before, emptied.after} == {%{"name" => "Acme Agents"}, %{"name" => nil}}
    end
  end

  describe "rename/2, for anyone else" do
    test "is refused, and changes nothing", %{scope: scope} do
      member = member_fixture(scope)
      refute Apiary.Access.instance_admin?(member.scope)
      assert {:error, :forbidden} = rename(member.scope, "Acme Agents")

      %{scope: other} = sign_up_fixture()
      refute Apiary.Access.instance_admin?(other)
      assert {:error, :forbidden} = rename(other, "Acme Agents")

      assert {:error, :forbidden} = rename(nil, "Acme Agents")

      assert ProductName.get() == nil
      assert entries() == []
    end
  end

  describe "powered_by?/1" do
    test "only beside a name set that is not Qory Apiary, where the edition carries the line" do
      assert Apiary.Edition.attribution?()
      refute ProductName.powered_by?(nil)
      refute ProductName.powered_by?("Qory Apiary")
      assert ProductName.powered_by?("Acme Agents")
    end
  end

  describe "hold/0, a live page's" do
    test "reads the name once for the process, until it renames the instance", %{scope: scope} do
      on_exit(fn -> Process.delete({ProductName, :held}) end)
      :ok = ProductName.hold()
      assert ProductName.get() == nil

      # Set elsewhere: the process keeps the name it held.
      Repo.query!("""
      INSERT INTO instance_settings (id, product_name, updated_at) VALUES (true, 'Elsewhere', now())
      ON CONFLICT (id) DO UPDATE SET product_name = 'Elsewhere'
      """)

      assert ProductName.load() == "Elsewhere"
      assert ProductName.get() == nil

      assert {:ok, "Acme Agents"} = rename(scope, "Acme Agents")
      assert ProductName.get() == "Acme Agents"
    end
  end

  describe "Apiary.ProductName.Cache, each node's copy" do
    test "holds what the database has, reads it again on every rename, and leaves when it stops",
         %{scope: scope} do
      assert Cache.cached() == :error
      start_supervised!(Cache)
      assert Cache.cached() == {:ok, nil}

      assert {:ok, "Acme Agents"} = rename(scope, "Acme Agents")
      eventually(fn -> assert Cache.cached() == {:ok, "Acme Agents"} end)
      assert ProductName.name() == "Acme Agents"

      assert {:ok, nil} = rename(scope, "")
      eventually(fn -> assert Cache.cached() == {:ok, nil} end)
      assert ProductName.name() == "Qory Apiary"

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
