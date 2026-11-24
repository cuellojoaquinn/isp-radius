# Laboratorio RADIUS ISP — VMs de servidores (provider: VirtualBox).
#
# Crea tres VMs Debian 12 en la red interna de VirtualBox "gestion" (10.10.10.0/24):
#   db          10.10.10.20   PostgreSQL en Docker
#   freeradius  10.10.10.10   FreeRADIUS en Docker
#   grafana     10.10.10.30   monitoreo: Prometheus, Alertmanager, Grafana, Loki
#
# R1 (MikroTik CHR) y los abonados NO se crean acá: se importan a mano en
# VirtualBox. El adaptador de R1 que hace de ether1 va en "Red interna" con
# nombre "gestion" e IP 10.10.10.1/24. Ver README.md.
#
# Antes de `vagrant up`: crear freeradius/.env, db/.env y grafana/.env desde
# los .env.example.
#
# La red "gestion" es interna de VirtualBox: desde el host no se llega. Por eso
# la VM grafana redirige sus interfaces web a localhost del host:
#   Grafana http://localhost:3000   Prometheus :9090   Alertmanager :9093

VMS = [
  { name: "db",         ip: "10.10.10.20", compose: "db" },
  { name: "freeradius", ip: "10.10.10.10", compose: "freeradius" },
  { name: "grafana",    ip: "10.10.10.30", compose: "grafana", memory: 2048,
    ports: [3000, 9090, 9093] },
]

Vagrant.configure("2") do |config|
  config.vm.box = "debian/bookworm64"

  config.vm.provider "virtualbox" do |vb|
    vb.memory = 1024
    vb.cpus   = 1
  end

  config.vm.provision "base", type: "shell", path: "scripts/base.sh"

  VMS.each do |vm|
    config.vm.define vm[:name] do |m|
      m.vm.hostname = vm[:name]

      # Segunda interfaz en la red de gestión, sin gateway
      # (la salida a internet es la NAT de Vagrant)
      m.vm.network "private_network", ip: vm[:ip], virtualbox__intnet: "gestion"

      # Prometheus (35 días de métricas) y Loki (14 días de logs): necesita más memoria
      if vm[:memory]
        m.vm.provider("virtualbox") { |vb| vb.memory = vm[:memory] }
      end

      # Interfaces web accesibles solo desde el propio host (127.0.0.1)
      (vm[:ports] || []).each do |p|
        m.vm.network "forwarded_port", guest: p, host: p, host_ip: "127.0.0.1"
      end

      # Levanta el compose de esa VM si existe (en cada `vagrant up`)
      m.vm.provision "compose", type: "shell", run: "always", inline: <<-SHELL
        cd /vagrant/#{vm[:compose]}
        if [ -f docker-compose.yml ]; then
          [ -f .env ] || { echo "Falta #{vm[:compose]}/.env (copiar desde .env.example)"; exit 1; }
          docker-compose up -d
        fi
      SHELL

      # Prueba automática: corre sola al final de cada `vagrant up` de freeradius.
      # A mano: vagrant provision freeradius --provision-with test
      if vm[:name] == "freeradius"
        m.vm.provision "test", type: "shell", run: "always", path: "scripts/test.sh"
      end
    end
  end
end
