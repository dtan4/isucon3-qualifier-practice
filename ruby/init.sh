#!/bin/sh

mysql -u isucon isucon < /home/isucon/webapp/ruby/add_index.sql

memo_total=$(mysql -uisucon isucon <<EOS | egrep '[0-9]+'
SELECT count(*) FROM memos WHERE is_private=0
EOS
)

redis-cli set isucon3:memo:total $memo_total
