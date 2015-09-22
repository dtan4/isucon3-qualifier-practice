alter table `memos` add index `memos_is_private_idx` (`is_private`);
alter table `memos` add index `index memos_user_idx` (`user`);
alter table `memos` add index `memos_user_is_private_created_at_idx` (`user`, `is_private`, `created_at`);
alter table `memos` add index `memos_is_private_created_at_id_idx` (`is_private`, `created_at`, `id`);
