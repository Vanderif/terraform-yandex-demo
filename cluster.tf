data "template_file" "master" {
  count = "${yandex_compute_instance.master.count}"

  template = "${file("cluster/master_node.yml.tpl")}"

  vars {
    name   = "${element(yandex_compute_instance.master.*.name, count.index)}"
    user   = "${var.username}"
    int_ip = "${element(yandex_compute_instance.master.*.network_interface.0.ip_address, count.index)}"
    nat_ip = "${element(yandex_compute_instance.master.*.network_interface.0.nat_ip_address, count.index)}"
  }
}


data "template_file" "worker" {
  count = "${yandex_compute_instance.worker.count}"

  template = "${file("cluster/worker_node.yml.tpl")}"

  vars {
    name   = "${element(yandex_compute_instance.worker.*.name, count.index)}"
    user   = "${var.username}"
    int_ip = "${element(yandex_compute_instance.worker.*.network_interface.0.ip_address, count.index)}"
    nat_ip = "${element(yandex_compute_instance.worker.*.network_interface.0.nat_ip_address, count.index)}"
  }
}


data "template_file" "cluster-config" {
  template = "${file("cluster/cluster.yml.tpl")}"

  vars {
    cluster      = "${var.cluster_name}"
    private_key  = "${var.private_key_file}"
    master_nodes = "${join("\n", data.template_file.master.*.rendered)}"
    worker_nodes = "${join("\n", data.template_file.worker.*.rendered)}"
  }
}


data "template_file" "masterhosts" {
  count = "${yandex_compute_instance.master.count}"

  template = "${file("cluster/hosts.tpl")}"
  vars {
    nat_ip = "${element(yandex_compute_instance.master.*.network_interface.0.nat_ip_address, count.index)}"
    name   = "${element(yandex_compute_instance.master.*.name, count.index)}"
  }
}


data "template_file" "workerhosts" {
  count = "${yandex_compute_instance.master.count}"

  template = "${file("cluster/hosts.tpl")}"
  vars {
    nat_ip = "${element(yandex_compute_instance.worker.*.network_interface.0.nat_ip_address, count.index)}"
    name   = "${element(yandex_compute_instance.worker.*.name, count.index)}"
  }
}


data "template_file" "clusterhosts" {
  template = "${file("cluster/clusterhosts.tpl")}"

  vars {
    master_nodes = "${join("\n", data.template_file.masterhosts.*.rendered)}"
    worker_nodes = "${join("\n", data.template_file.workerhosts.*.rendered)}"
  }
}


output "cluster" {
  value = "${data.template_file.cluster-config.rendered}"
}


data "template_file" "config_file" {
  template = "${var.output_path}${var.cluster_name}.yml"
}


data "template_file" "kubeconfig_file" {
  template = "${var.output_path}kube_config_${var.cluster_name}.yml"
}


resource "null_resource" "cluster" {
  triggers {
    config = "${data.template_file.cluster-config.rendered}"
  }

  provisioner "local-exec" {
    command = "test -e ${var.output_path} || mkdir -p ${var.output_path}"
  }

  provisioner "local-exec" {
    command = "rm -rf ${var.output_path}*"
  }

  provisioner "local-exec" {
    command = "test -e ${data.template_file.config_file.rendered} || rm -rf ${data.template_file.config_file.rendered}"
  }

  provisioner "local-exec" {
    command = "echo \"${data.template_file.cluster-config.rendered}\" > ${data.template_file.config_file.rendered}"
  }

  provisioner "local-exec" {
    command = "test -e ${var.private_key_file} || echo \"${tls_private_key.ssh-key.private_key_pem}\" > ${var.private_key_file} && chmod 400 ${var.private_key_file}"
  }

  provisioner "local-exec" {
    command = "test -e ${data.template_file.kubeconfig_file.rendered} && scripts/rke.sh ${data.template_file.config_file.rendered} up --update-only  || scripts/rke.sh ${data.template_file.config_file.rendered} up"
  }
}


resource "null_resource" "kubectl_init" {
	depends_on = ["null_resource.cluster"]

    count = "${yandex_compute_instance.master.count}"
    
    provisioner "file" {
      source = "${data.template_file.kubeconfig_file.rendered}"
      destination = "/home/${var.username}/.kube/config"

      connection {
        host = "${element(yandex_compute_instance.master.*.network_interface.0.nat_ip_address, count.index)}"
        type = "ssh"
        user = "${var.username}"
        private_key = "${tls_private_key.ssh-key.private_key_pem}"
      }
    }

    provisioner "remote-exec" {
      inline = [
        "sudo sh -c \"echo '${data.template_file.clusterhosts.rendered}' >> /etc/hosts\""
      ]

      connection {
        host = "${element(yandex_compute_instance.master.*.network_interface.0.nat_ip_address, count.index)}"
        type = "ssh"
        user = "${var.username}"
        private_key = "${tls_private_key.ssh-key.private_key_pem}"
      }
    }
}


output "kubeconfig" {
  value = "${data.template_file.kubeconfig_file.rendered}"
}

output "promptrancher" {
	value = "To unstall Rancher run on master node: sudo docker run -d --restart=unless-stopped -p 80:80 -p 443:443 rancher/rancher"
}