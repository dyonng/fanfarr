defmodule FanfarrWeb.PaginationTest do
  @moduledoc "The library pager's page-number strip."
  use ExUnit.Case, async: true

  alias FanfarrWeb.LibraryLive.Index, as: Library

  describe "page_numbers/2" do
    test "a short run is listed in full, with no gaps" do
      assert Library.page_numbers(1, 5) == [1, 2, 3, 4, 5]
      assert Library.page_numbers(3, 5) == [1, 2, 3, 4, 5]
    end

    test "first and last stay reachable from the middle of a long run" do
      numbers = Library.page_numbers(30, 60)

      assert hd(numbers) == 1
      assert List.last(numbers) == 60
      assert 30 in numbers
    end

    test "the current page keeps two neighbours either side" do
      assert Library.page_numbers(30, 60) == [1, :gap, 28, 29, 30, 31, 32, :gap, 60]
    end

    test "a single hidden page is filled in rather than gapped" do
      # An ellipsis standing in for just page 7 takes as much room as the 7
      # would, and tells the reader less.
      assert Library.page_numbers(4, 8) == [1, 2, 3, 4, 5, 6, 7, 8]
    end

    test "near either end there is only one gap" do
      assert Library.page_numbers(1, 60) == [1, 2, 3, :gap, 60]
      assert Library.page_numbers(60, 60) == [1, :gap, 58, 59, 60]
    end

    test "a single page is just itself" do
      assert Library.page_numbers(1, 1) == [1]
    end

    test "a page beyond the end still produces a usable strip" do
      assert Library.page_numbers(99, 3) == [1, 2, 3]
    end
  end
end
