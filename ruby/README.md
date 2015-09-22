### HOT TO RUN ###

    $ gem install bundler foreman
    $ bundle install --deployment --without development
    $ foreman start

### rsync

```bash
$ rsync -lprtvu --exclude .git* . isucon3:/home/isucon/webapp/ruby
```
