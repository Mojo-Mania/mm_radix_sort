"""Radix sorts for Mojo.

`radix_sort` is the entry point: it dispatches on the element type and the
size of the input, using thresholds measured by the suite in `benchmarks/`.
The strategies it chooses between are public too, for when you know something
it does not.

```mojo
from mm_radix_sort import radix_sort

var values = [Int32(5), -3, 9, -1]
var span = Span(values)
radix_sort(span)
print(values)  # [-3, -1, 5, 9]
```
"""

from .bytes import byte_radix_sort
from .lsb import lsb_radix_sort
from .msb import american_flag_sort, msb_radix_sort
from .radix_sort import radix_sort
