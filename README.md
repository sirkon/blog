# blog
Binary logging.

# Log record storage format.

| 0xff | CRC32 | uvarint (record_size) | timestamp (u64) | level | …whatever else… | uvarint (message size) | message | payload |
|-|-|-|-|-|-|-|-|-|

And this thing with 0xff + CRC32 + size plays a role similar to \n with text logs: it allows to pass broken records.

