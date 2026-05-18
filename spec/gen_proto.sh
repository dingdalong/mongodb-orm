cd $(dirname $0)
lua ../tools/proto2lua.lua proto_define.lua proto
lua ../tools/gen_schema.lua proto/schema.lua proto_define.lua
rm proto_define.lua
