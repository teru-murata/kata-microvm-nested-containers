VM := kata-poc
SHELL := /bin/bash

.PHONY: up provision test logs down clean

# Bring up the Lima VM (with the raw devmapper disk) and provision Kata + k3s.
up:
	-limactl disk create katapool --size 50GiB --format raw
	limactl start --name=$(VM) --tty=false lima/kata-poc.yaml
	$(MAKE) provision

provision:
	limactl copy setup/provision.sh $(VM):/tmp/provision.sh
	limactl shell $(VM) bash /tmp/provision.sh

# Launch the non-privileged box and run a nested container inside the microVM.
test:
	limactl copy box.yaml $(VM):/tmp/box.yaml
	-limactl shell $(VM) sudo k3s kubectl delete pod box --ignore-not-found --force --grace-period=0
	limactl shell $(VM) sudo k3s kubectl apply -f /tmp/box.yaml
	limactl shell $(VM) sudo k3s kubectl wait --for=condition=Ready pod/box --timeout=240s
	@echo "running the nested-container test (give it ~60s for the pull + run)..."
	@until limactl shell $(VM) sudo k3s kubectl logs box 2>/dev/null | grep -q "=== DONE ==="; do sleep 8; done
	@echo "----------------------------------------"
	@limactl shell $(VM) sudo k3s kubectl logs box

logs:
	limactl shell $(VM) sudo k3s kubectl logs box

# Tear everything down.
down clean:
	-limactl stop -f $(VM)
	-limactl delete -f $(VM)
	-limactl disk delete katapool
