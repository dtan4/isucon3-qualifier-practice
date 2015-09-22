create index memos_is_private_idx on memos(is_private);
create index memos_user_idx on memos(user);
create index memos_user_and_is_private_idx on memos(user, is_private);
