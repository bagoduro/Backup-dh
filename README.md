Onde está instalado o dh-p2p, você cria o tunel com o dispositivo:

vai rodar esse comando, vai aparecer um monte de coisa e vai criar o tunel, com o tunel criado, vc abre outro prompt
  ./target/release/dh-p2p 3K04BD5PAG00028 -p 127.0.0.1:8080:80 --relay

e roda isso:

 curl -v 'http://127.0.0.1:8080/cgi-bin/userManager.cgi?action=addUser&user.Name=pdr&user.Password=Pass123!&user.Group=admin&user.Sharable=true&user.Reserved=false&user.Memo='
