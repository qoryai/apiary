defmodule Apiary.InvitationDeliveryTest do
  # Not async: the mailer's adapter is application configuration.
  use Apiary.DataCase, async: false

  import Apiary.OrganisationsFixtures

  alias Apiary.Organisations
  alias Apiary.Organisations.Invitation

  setup do
    # The sign-up fixture confirms its user by email, so it runs on the real adapter.
    %{scope: scope} = sign_up_fixture()
    previous = Application.fetch_env!(:apiary, Apiary.Mailer)
    Application.put_env(:apiary, Apiary.Mailer, adapter: Apiary.FailingMailAdapter)
    on_exit(fn -> Application.put_env(:apiary, Apiary.Mailer, previous) end)
    %{previous: previous, scope: scope}
  end

  test "H3: an invitation that could not be delivered is not kept", %{
    previous: previous,
    scope: scope
  } do
    attrs = %{"email" => "nobody@example.com", "level" => "member"}
    url_fun = &"http://localhost/invitations/#{&1}"

    assert {:error, :delivery_failed} = Organisations.invite_member(scope, attrs, url_fun)
    assert Repo.all(Invitation) == []
    assert Organisations.list_invitations(scope) == []

    # The address is free again once mail works.
    Application.put_env(:apiary, Apiary.Mailer, previous)
    assert {:ok, %Invitation{}} = Organisations.invite_member(scope, attrs, url_fun)
  end
end
