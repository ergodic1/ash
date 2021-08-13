defmodule Ash.DataLayer.EtsTest do
  use ExUnit.Case, async: false

  import Ash.Test.Helpers

  alias Ash.DataLayer.Ets, as: EtsDataLayer
  alias Ash.DataLayer.Ets.Query

  require Ash.Query

  setup do
    on_exit(fn ->
      case ETS.Set.wrap_existing(EtsTestUser) do
        {:error, :table_not_found} -> :ok
        {:ok, set} -> ETS.Set.delete_all!(set)
      end
    end)
  end

  defmodule EtsTestUser do
    use Ash.Resource, data_layer: Ash.DataLayer.Ets

    ets do
      private?(true)
    end

    actions do
      read(:read)
      create(:create)
      update(:update)
      destroy(:destroy)
    end

    attributes do
      uuid_primary_key :id, writable?: true
      attribute :name, :string
      attribute :age, :integer
      attribute :title, :string
    end
  end

  defmodule EtsApiTest do
    use Ash.Api

    resources do
      resource EtsTestUser
    end
  end

  test "resource_to_query" do
    assert %Query{resource: EtsTestUser} = EtsDataLayer.resource_to_query(EtsTestUser, nil)
  end

  test "limit, offset, filter, sort" do
    query = EtsDataLayer.resource_to_query(EtsTestUser, nil)
    assert {:ok, %Query{limit: 3}} = EtsDataLayer.limit(query, 3, :foo)
    assert {:ok, %Query{offset: 10}} = EtsDataLayer.offset(query, 10, :foo)
    assert {:ok, %Query{filter: :all}} = EtsDataLayer.filter(query, :all, :foo)
    assert {:ok, %Query{sort: :asc}} = EtsDataLayer.sort(query, :asc, :foo)
  end

  test "create" do
    assert %EtsTestUser{id: id, name: "Mike"} = create_user(%{name: "Mike"})

    assert [{%{id: ^id}, %EtsTestUser{name: "Mike", id: ^id}}] = user_table()
  end

  test "update" do
    %EtsTestUser{id: id} = user = create_user(%{name: "Mike"})

    assert [{%{id: ^id}, %EtsTestUser{id: ^id, name: "Mike"}}] = user_table()

    user
    |> Ash.Changeset.new(name: "Joe")
    |> EtsApiTest.update!()

    assert [{%{id: ^id}, %EtsTestUser{name: "Joe", id: ^id}}] = user_table()
  end

  test "upsert" do
    %EtsTestUser{id: id} = create_user(%{name: "Mike"}, upsert?: true)

    assert [{%{id: ^id}, %EtsTestUser{id: ^id, name: "Mike"}}] = user_table()

    create_user(%{name: "Joe", id: id}, upsert?: true)

    assert [{%{id: ^id}, %EtsTestUser{name: "Joe", id: ^id}}] = user_table()
  end

  test "destroy" do
    mike = create_user(%{name: "Mike"})
    %EtsTestUser{id: joes_id} = joe = create_user(%{name: "Joe"})

    assert length(user_table()) == 2

    EtsApiTest.destroy!(mike)

    assert [{%{id: ^joes_id}, ^joe}] = user_table()
  end

  test "get" do
    create_user(%{name: "Mike"})
    create_user(%{name: "Joe"})
    %{id: id} = create_user(%{name: "Matthew"})
    create_user(%{name: "Zachary"})

    assert %EtsTestUser{id: ^id, name: "Matthew"} = EtsApiTest.get!(EtsTestUser, id)
  end

  test "sort" do
    mike = create_user(%{name: "Mike"})
    joe = create_user(%{name: "Joe"})
    matthew = create_user(%{name: "Matthew"})
    zachary = create_user(%{name: "Zachary"})

    query =
      EtsTestUser
      |> Ash.Query.new()
      |> Ash.Query.sort(:name)

    assert [^joe, ^matthew, ^mike, ^zachary] = clear_meta(EtsApiTest.read!(query))
  end

  test "limit" do
    _mike = create_user(%{name: "Mike"})
    joe = create_user(%{name: "Joe"})
    matthew = create_user(%{name: "Matthew"})
    _zachary = create_user(%{name: "Zachary"})

    query =
      EtsTestUser
      |> Ash.Query.new()
      |> Ash.Query.sort(:name)
      |> Ash.Query.limit(2)

    assert [^joe, ^matthew] = clear_meta(EtsApiTest.read!(query))
  end

  test "offset" do
    mike = create_user(%{name: "Mike"})
    _joe = create_user(%{name: "Joe"})
    matthew = create_user(%{name: "Matthew"})
    zachary = create_user(%{name: "Zachary"})

    query =
      EtsTestUser
      |> Ash.Query.new()
      |> Ash.Query.sort(:name)
      |> Ash.Query.offset(1)

    assert [^matthew, ^mike, ^zachary] = clear_meta(EtsApiTest.read!(query))
  end

  describe "filter" do
    setup do
      mike = create_user(%{name: "Mike", age: 37, title: "Dad"})
      joe = create_user(%{name: "Joe", age: 11})
      matthew = create_user(%{name: "Matthew", age: 9})
      zachary = create_user(%{name: "Zachary", age: 6})
      %{mike: mike, zachary: zachary, matthew: matthew, joe: joe}
    end

    test "values", %{zachary: zachary, matthew: matthew, joe: joe} do
      assert [^zachary] = clear_meta(filter_users(name: "Zachary"))
      assert [^joe] = clear_meta(filter_users(name: "Joe"))
      assert [^matthew] = clear_meta(filter_users(age: 9))
    end

    test "or, in, eq", %{mike: mike, zachary: zachary, joe: joe} do
      assert [^joe, ^mike, ^zachary] =
               clear_meta(
                 filter_users(
                   or: [
                     [name: [in: ["Zachary", "Mike"]]],
                     [age: [eq: 11]]
                   ]
                 )
               )
    end

    test "and, in, eq", %{mike: mike} do
      assert [^mike] =
               clear_meta(
                 filter_users(
                   and: [
                     [name: [in: ["Zachary", "Mike"]]],
                     [age: [eq: 37]]
                   ]
                 )
               )
    end

    test "and, in, not", %{zachary: zachary} do
      assert [^zachary] =
               clear_meta(
                 filter_users(
                   and: [
                     [name: [in: ["Zachary", "Mike"]]],
                     [not: [age: 37]]
                   ]
                 )
               )
    end

    test "gt", %{mike: mike, joe: joe} do
      assert [^joe, ^mike] = clear_meta(filter_users(age: [gt: 10]))
    end

    test "lt", %{zachary: zachary, matthew: matthew} do
      assert [^matthew, ^zachary] = clear_meta(filter_users(age: [lt: 10]))
    end

    test "boolean", %{zachary: zachary, matthew: matthew} do
      assert [^matthew, ^zachary] = clear_meta(filter_users(and: [true, age: [lt: 10]]))
    end

    test "is_nil", %{zachary: zachary, matthew: matthew, joe: joe} do
      assert [^joe, ^matthew, ^zachary] = clear_meta(filter_users(title: [is_nil: true]))
    end
  end

  defp filter_users(filter) do
    EtsTestUser
    |> Ash.Query.new()
    |> Ash.Query.sort(:name)
    |> Ash.Query.filter(^filter)
    |> EtsApiTest.read!()
  end

  defp create_user(attrs, opts \\ []) do
    EtsTestUser
    |> Ash.Changeset.new(attrs)
    |> EtsApiTest.create!(opts)
  end

  defp user_table do
    EtsTestUser
    |> ETS.Set.wrap_existing!()
    |> ETS.Set.to_list!()
  end
end
