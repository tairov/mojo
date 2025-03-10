# ===----------------------------------------------------------------------=== #
# Copyright (c) 2025, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Defines the `InlineArray` type.

You can import these APIs from the `collections` package. For example:

```mojo
from collections import InlineArray
```
"""

from collections._index_normalization import normalize_index
from sys.intrinsics import _type_is_eq

from memory import UnsafePointer
from memory.maybe_uninitialized import UnsafeMaybeUninitialized

# ===-----------------------------------------------------------------------===#
# Array
# ===-----------------------------------------------------------------------===#


fn _inline_array_construction_checks[size: Int]():
    """Checks if the properties in `InlineArray` are valid.

    Validity right now is just ensuring the number of elements is > 0.

    Parameters:
      size: The number of elements.
    """
    constrained[size > 0, "number of elements in `InlineArray` must be > 0"]()


@value
struct InlineArray[
    ElementType: CollectionElement,
    size: Int,
    *,
    run_destructors: Bool = False,
](Sized, Movable, Copyable, ExplicitlyCopyable):
    """A fixed-size sequence of size homogeneous elements where size is a constant expression.

    Parameters:
        ElementType: The type of the elements in the array.
        size: The size of the array.
        run_destructors: Whether to run destructors on the elements.  Defaults to False for *backwards compatibility* reasons only.  Eventually this will default to `True` and/or the parameter will be removed to unconditionally run destructors on the elements.
    """

    # Fields
    alias type = __mlir_type[
        `!pop.array<`, size.value, `, `, Self.ElementType, `>`
    ]
    var _array: Self.type
    """The underlying storage for the array."""

    # ===------------------------------------------------------------------===#
    # Life cycle methods
    # ===------------------------------------------------------------------===#

    @always_inline
    fn __init__(out self):
        """This constructor will always cause a compile time error if used.
        It is used to steer users away from uninitialized memory.
        """
        constrained[
            False,
            (
                "Initialize with either a variadic list of arguments, a default"
                " fill element or pass the keyword argument"
                " 'unsafe_uninitialized'."
            ),
        ]()
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(self))

    @always_inline
    fn __init__(out self, *, unsafe_uninitialized: Bool):
        """Create an InlineArray with uninitialized memory.

        Note that this is highly unsafe and should be used with caution.

        We recommend to use the `InlineList` instead if all the objects
        are not available when creating the array.

        If despite those workarounds, one still needs an uninitialized array,
        it is possible with:

        ```mojo
        var uninitialized_array = InlineArray[Int, 10](unsafe_uninitialized=True)
        ```

        Args:
            unsafe_uninitialized: A boolean to indicate if the array should be initialized.
                Always set to `True` (it's not actually used inside the constructor).
        """
        _inline_array_construction_checks[size]()
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(self))

    fn __init__(
        mut self,
        *,
        owned unsafe_assume_initialized: InlineArray[
            UnsafeMaybeUninitialized[Self.ElementType], Self.size
        ],
    ):
        """Constructs an `InlineArray` from an `InlineArray` of `UnsafeMaybeUninitialized`.

        Calling this function assumes that all elements in the input array are initialized.

        If the elements of the input array are not initialized, the behavior is undefined,
        even  if `ElementType` is valid *for every possible bit pattern* (e.g. `Int` or `Float`).

        Args:
            unsafe_assume_initialized: The array of `UnsafeMaybeUninitialized` elements.
        """

        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(self))
        for i in range(Self.size):
            unsafe_assume_initialized[i].unsafe_ptr().move_pointee_into(
                self.unsafe_ptr() + i
            )

    @always_inline
    @implicit
    fn __init__(out self, fill: Self.ElementType):
        """Constructs an empty array where each element is the supplied `fill`.

        Args:
            fill: The element to fill each index.
        """
        _inline_array_construction_checks[size]()
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(self))

        @parameter
        for i in range(size):
            var ptr = UnsafePointer.address_of(self.unsafe_get(i))
            ptr.init_pointee_copy(fill)

    @always_inline
    @implicit
    fn __init__(out self, owned *elems: Self.ElementType):
        """Constructs an array given a set of arguments.

        Args:
            elems: The element types.
        """

        self = Self(storage=elems^)

    @always_inline
    fn __init__(
        mut self,
        *,
        owned storage: VariadicListMem[Self.ElementType, _],
    ):
        """Construct an array from a low-level internal representation.

        Args:
            storage: The variadic list storage to construct from.
        """

        debug_assert(len(storage) == size, "Elements must be of length size")
        _inline_array_construction_checks[size]()
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(self))

        # Move each element into the array storage.
        @parameter
        for i in range(size):
            var eltptr = UnsafePointer.address_of(self.unsafe_get(i))
            UnsafePointer.address_of(storage[i]).move_pointee_into(eltptr)

        # Do not destroy the elements when their backing storage goes away.
        __disable_del storage

    fn copy(self) -> Self:
        """Explicitly copy the provided value.

        Returns:
            A copy of the value.
        """

        var copy = Self(unsafe_uninitialized=True)

        for idx in range(size):
            var ptr = copy.unsafe_ptr() + idx
            ptr.init_pointee_copy(self[idx])

        return copy^

    fn __copyinit__(out self, other: Self):
        """Copy construct the array.

        Args:
            other: The array to copy.
        """

        self = other.copy()

    fn __del__(owned self):
        """Deallocate the array."""

        @parameter
        if Self.run_destructors:

            @parameter
            for idx in range(size):
                var ptr = self.unsafe_ptr() + idx
                ptr.destroy_pointee()

    # ===------------------------------------------------------------------===#
    # Operator dunders
    # ===------------------------------------------------------------------===#

    @always_inline
    fn __getitem__[I: Indexer](ref self, idx: I) -> ref [self] Self.ElementType:
        """Get a `Pointer` to the element at the given index.

        Parameters:
            I: A type that can be used as an index.

        Args:
            idx: The index of the item.

        Returns:
            A reference to the item at the given index.
        """
        var normalized_index = normalize_index["InlineArray"](idx, len(self))
        return self.unsafe_get(normalized_index)

    @always_inline
    fn __getitem__[
        I: Indexer, //, idx: I
    ](ref self) -> ref [self] Self.ElementType:
        """Get a `Pointer` to the element at the given index.

        Parameters:
            I: A type that can be used as an index.
            idx: The index of the item.

        Returns:
            A reference to the item at the given index.
        """
        constrained[-size <= Int(idx) < size, "Index must be within bounds."]()
        alias normalized_index = normalize_index["InlineArray"](idx, size)
        return self.unsafe_get(normalized_index)

    # ===------------------------------------------------------------------=== #
    # Trait implementations
    # ===------------------------------------------------------------------=== #

    @always_inline
    fn __len__(self) -> Int:
        """Returns the length of the array. This is a known constant value.

        Returns:
            The size of the array.
        """
        return size

    # ===------------------------------------------------------------------===#
    # Methods
    # ===------------------------------------------------------------------===#

    @always_inline
    fn unsafe_get[I: Indexer](ref self, idx: I) -> ref [self] Self.ElementType:
        """Get a reference to an element of self without checking index bounds.

        Users should opt for `__getitem__` instead of this method as it is
        unsafe.

        Note that there is no wraparound for negative indices. Using negative
        indices is considered undefined behavior.

        Args:
            idx: The index of the element to get.

        Parameters:
            I: A type that can be used as an index.

        Returns:
            A reference to the element at the given index.
        """
        var i = index(idx)
        debug_assert(
            0 <= Int(i) < size,
            " InlineArray.unsafe_get() index out of bounds: ",
            Int(idx),
            " should be less than: ",
            size,
        )
        var ptr = __mlir_op.`pop.array.gep`(
            UnsafePointer.address_of(self._array).address,
            i,
        )
        return UnsafePointer(ptr)[]

    @always_inline
    fn unsafe_ptr(
        ref self,
    ) -> UnsafePointer[
        Self.ElementType,
        mut = Origin(__origin_of(self)).is_mutable,
        origin = __origin_of(self),
    ]:
        """Get an `UnsafePointer` to the underlying array.

        That pointer is unsafe but can be used to read or write to the array.
        Be careful when using this. As opposed to a pointer to a `List`,
        this pointer becomes invalid when the `InlineArray` is moved.

        Make sure to refresh your pointer every time the `InlineArray` is moved.

        Returns:
            An `UnsafePointer` to the underlying array.
        """
        return UnsafePointer.address_of(self._array).bitcast[Self.ElementType]()

    @always_inline
    fn __contains__[
        T: EqualityComparableCollectionElement, //
    ](self: InlineArray[T, size], value: T) -> Bool:
        """Verify if a given value is present in the array.

        ```mojo
        from collections import InlineArray
        var x = InlineArray[Int, 3](1,2,3)
        if 3 in x: print("x contains 3")
        ```

        Parameters:
            T: The type of the elements in the array. Must implement the
              traits `EqualityComparable` and `CollectionElement`.

        Args:
            value: The value to find.

        Returns:
            True if the value is contained in the array, False otherwise.
        """

        @parameter
        for i in range(size):
            if self[i] == value:
                return True
        return False
