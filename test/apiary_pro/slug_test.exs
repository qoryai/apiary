defmodule ApiaryPro.SlugTest do
  # A new organisation's slug under the edition: a name the edition reserves beside the core's
  # (`ApiaryProWeb.Edition.reserved_slugs/0`, `ApiaryWeb.ReservedSlugs`) is refused, not
  # numbered.
  use Apiary.DataCase, async: true

  import Apiary.AccountsFixtures, only: [valid_user_attributes: 1]

  for {name, address} <- [{"Support", "/support"}, {"Admin", "/admin"}] do
    @name name
    @address address

    test "an organisation named #{@name} is refused, as Qory Apiary keeps #{@address}" do
      attrs = valid_user_attributes(%{organisation_name: @name})

      assert {:error, %Ecto.Changeset{} = form} =
               Apiary.Organisations.sign_up_user(attrs, nil, open: true)

      assert %{
               organisation_name: [
                 "Choose another name. Qory Apiary keeps the address #{@address}."
               ]
             } =
               errors_on(form)
    end
  end
end
