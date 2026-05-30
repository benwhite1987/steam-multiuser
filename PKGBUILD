# Maintainer: Benjamin White <benwhite1987@gmail.com>
pkgname=steam-multiuser
pkgver=1.0.0
pkgrel=1
pkgdesc="Shared Steam game library manager for multi-user Linux systems"
arch=('any')
url="https://github.com/benwhite1987/steam-multiuser"
license=('GPL-2.0-or-later')
depends=('bash' 'pam' 'util-linux' 'rsync' 'systemd')
optdepends=('steam: the games this manages')
# Steam itself lives in multilib; not a hard dependency of this tool.
backup=('etc/steam-multiuser.conf')
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')  # replace with the real checksum at release time

package() {
    cd "$srcdir/$pkgname-$pkgver"

    # Main script
    install -Dm755 steam-multiuser.sh "$pkgdir/usr/bin/steam-multiuser.sh"

    # Example configuration (installed as .example; user copies to the real path)
    install -Dm644 steam-multiuser.conf.example \
        "$pkgdir/etc/steam-multiuser.conf.example"

    # Documentation
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
