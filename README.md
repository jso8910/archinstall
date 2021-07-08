# My arch install script
It is simple: just run these commands in the ISO.
```bash
$ pacman -Sy git
$ git clone https://github.com/jso8910/archinstall
$ cd archinstall
```
Then tinker with the config in the `config` file. Finally

```bash
$ ./install.sh
```

If you get a `Permission denied` just run `$ chmod +x install.sh`.
