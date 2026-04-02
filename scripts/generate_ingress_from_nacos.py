#!/usr/bin/env python3
"""
从 Nacos 获取 Dubbo 服务并同步到 Higress Ingress 配置
"""

import sys
import json
import argparse
import urllib.parse
import urllib.request
import subprocess
from typing import Optional, Dict, Any, List

def dict_to_yaml(data: Dict[str, Any], indent: int = 0) -> str:
    """简单将 dict 转为 YAML 格式字符串"""
    lines = []
    prefix = "  " * indent
    for key, value in data.items():
        if isinstance(value, dict):
            lines.append(f"{prefix}{key}:")
            lines.append(dict_to_yaml(value, indent + 1))
        elif isinstance(value, list):
            lines.append(f"{prefix}{key}:")
            for item in value:
                if isinstance(item, dict):
                    lines.append(f"{prefix}  -")
                    for k, v in item.items():
                        if isinstance(v, dict):
                            lines.append(f"{prefix}    {k}:")
                            lines.append(dict_to_yaml(v, indent + 3))
                        else:
                            lines.append(f"{prefix}    {k}: {v}")
                else:
                    lines.append(f"{prefix}  - {item}")
        else:
            lines.append(f"{prefix}{key}: {value}")
    return "\n".join(lines)

# 颜色定义
class Colors:
    BLUE = '\033[0;34m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    NC = '\033[0m'


def run_kubectl(args: List[str]) -> Optional[str]:
    """执行 kubectl 命令并返回输出"""
    try:
        result = subprocess.run(
            ['kubectl'] + args,
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode == 0:
            return result.stdout.strip()
        else:
            print(f"{Colors.RED}kubectl 错误: {result.stderr}{Colors.NC}", file=sys.stderr)
            return None
    except Exception as e:
        print(f"{Colors.RED}执行 kubectl 失败: {e}{Colors.NC}", file=sys.stderr)
        return None


def get_existing_ingresses() -> List[Dict[str, Any]]:
    """获取 Higress 中现有的 Ingress 列表"""
    result = run_kubectl(['get', 'ingresses', '-n', 'higress-system', '-o', 'json'])
    if result:
        try:
            data = json.loads(result)
            return data.get('items', [])
        except json.JSONDecodeError as e:
            print(f"{Colors.YELLOW}⚠ 解析 Ingress 列表失败: {e}{Colors.NC}")
    return []


def get_service_list(nacos_url: str, namespace_id: str, group_name: str) -> List[str]:
    """获取 Nacos 服务列表"""
    params = {'pageNo': '1', 'pageSize': '100'}
    if namespace_id:
        params['namespaceId'] = namespace_id
    if group_name:
        params['groupName'] = group_name

    url = f"{nacos_url}/nacos/v1/ns/service/list?{urllib.parse.urlencode(params)}"

    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            content = response.read().decode('utf-8')
            data = json.loads(content)
            return data.get('doms', [])
    except Exception as e:
        print(f"{Colors.RED}✗ 获取服务列表失败: {e}{Colors.NC}", file=sys.stderr)
        return []


def get_service_instances(nacos_url: str, service_name: str, group_name: str) -> List[Dict[str, Any]]:
    """获取服务的实例列表"""
    params = {'serviceName': service_name}
    if group_name:
        params['groupName'] = group_name

    url = f"{nacos_url}/nacos/v1/ns/instance/list?{urllib.parse.urlencode(params)}"

    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            content = response.read().decode('utf-8')
            data = json.loads(content)
            return data.get('hosts', [])
    except Exception as e:
        print(f"{Colors.RED}✗ 获取实例列表失败 [{service_name}]: {e}{Colors.NC}", file=sys.stderr)
        return []


def extract_dubbo_info(instance: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """从实例元数据中提取 Dubbo 接口信息（按接口粒度）"""
    metadata = instance.get('metadata', {})

    if metadata.get('dubbo') != '2.0.2':
        return None

    interface = metadata.get('interface', '')
    version = metadata.get('version', '')
    group = metadata.get('group', '')
    application = metadata.get('application', '')

    if not all([interface, version, application]):
        return None

    return {
        'interface': interface,
        'version': version,
        'group': group if group else 'public',
        'application': application,
        'service_name': interface.split('.')[-1],
    }


def collect_api_md5_from_services(nacos_url: str, services: List[str], group_name: str) -> Dict[str, str]:
    """从应用级服务实例中收集所有 api.md5.{interface} 元数据
    
    Args:
        nacos_url: Nacos 服务器地址
        services: 服务名称列表
        group_name: 服务分组
        
    Returns:
        字典: {interface: api_md5}
    """
    api_md5_map = {}
    
    for service_name in services:
        # 跳过 providers: 开头的服务（只查询应用级服务）
        if service_name.startswith('providers:'):
            continue
            
        try:
            params = {'serviceName': service_name}
            if group_name:
                params['groupName'] = group_name
            url = f"{nacos_url}/nacos/v1/ns/instance/list?{urllib.parse.urlencode(params)}"
            
            with urllib.request.urlopen(url, timeout=10) as response:
                content = response.read().decode('utf-8')
                data = json.loads(content)
                hosts = data.get('hosts', [])
                
                for instance in hosts:
                    metadata = instance.get('metadata', {})
                    # 提取所有 api.md5.{interface}:{version} 键
                    for key, value in metadata.items():
                        if key.startswith('api.md5.'):
                            # 格式: api.md5.{interface}:{version}
                            interface_with_version = key.replace('api.md5.', '')
                            api_md5_map[interface_with_version] = value
        except Exception:
            pass
    
    return api_md5_map


def check_metadata_exists(nacos_url: str, data_id: str, group: str) -> bool:
    """检查 Nacos 配置中心是否存在指定的 MetadataReport dataId"""
    params = {'dataId': data_id, 'group': group}
    url = f"{nacos_url}/nacos/v1/cs/configs?{urllib.parse.urlencode(params)}"

    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            content = response.read().decode('utf-8')
            data = json.loads(content)
            # 如果存在配置，data 中会有 content 字段
            return 'content' in data and data['content'] is not None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        print(f"{Colors.YELLOW}⚠ 查询 metadata 失败 [{data_id}]: HTTP {e.code}{Colors.NC}")
        return False
    except Exception as e:
        print(f"{Colors.YELLOW}⚠ 查询 metadata 失败 [{data_id}]: {e}{Colors.NC}")
        return False


def build_destination(svc: Dict[str, Any], nacos_group: str) -> str:
    """构建 destination 字符串
    格式: providers:{interface}:{version}:{group}.{nacos_group}.public.nacos
    """
    return f"providers:{svc['interface']}:{svc['version']}:{svc['group']}.{nacos_group}.public.nacos"


def build_ingress_name(svc: Dict[str, Any]) -> str:
    """构建 Ingress 名称：{application}-{service_name小写}-ingress"""
    return f"{svc['application']}-{svc['service_name'].lower()}-ingress"


def generate_ingress(svc: Dict[str, Any], domain: str, nacos_group: str) -> Dict[str, Any]:
    """生成 Ingress 配置（按接口粒度，path 使用接口全限定名）"""
    ingress_name = build_ingress_name(svc)
    destination = build_destination(svc, nacos_group)
    path = f"/dapi/{svc['interface']}"

    return {
        'apiVersion': 'networking.k8s.io/v1',
        'kind': 'Ingress',
        'metadata': {
            'name': ingress_name,
            'namespace': 'higress-system',
            'labels': {
                'managed-by': 'higress-deploy'
            },
            'annotations': {
                'higress.io/backend-protocol': 'grpc',
                'higress.io/destination': destination,
                'higress.io/auth-tls-secret': 'https-server-secret-cacert',
                'higress.io/auth-tls-verify-depth': '3',
                'higress.io/keepalive-timeout': '120s',
                'higress.io/keepalive-requests': '1000',
            }
        },
        'spec': {
            'ingressClassName': 'higress',
            'tls': [
                {
                    'hosts': [domain],
                    'secretName': 'https-server-secret'
                }
            ],
            'rules': [
                {
                    'host': domain,
                    'http': {
                        'paths': [
                            {
                                'path': path,
                                'pathType': 'Prefix',
                                'backend': {
                                    'resource': {
                                        'apiGroup': 'networking.higress.io',
                                        'kind': 'McpBridge',
                                        'name': 'default'
                                    }
                                }
                            }
                        ]
                    }
                }
            ]
        }
    }


def sync_ingress_to_higress(ingress: Dict[str, Any]) -> bool:
    """同步 Ingress 到 Higress (使用 kubectl apply)"""
    try:
        # 使用 kubectl apply -f - 从 stdin 读取 JSON
        json_content = json.dumps(ingress)

        result = subprocess.run(
            ['kubectl', 'apply', '-f', '-'],
            input=json_content,
            capture_output=True,
            text=True,
            timeout=30
        )

        if result.returncode == 0:
            return True
        else:
            # 检查是否是已存在的错误
            if 'AlreadyExists' in result.stderr or 'already exists' in result.stderr:
                print(f"{Colors.YELLOW}⚠ Ingress 已存在，跳过{Colors.NC}")
                return True
            print(f"{Colors.RED}✗ kubectl 错误: {result.stderr}{Colors.NC}")
            return False
    except Exception as e:
        print(f"{Colors.RED}✗ 同步失败: {e}{Colors.NC}")
        return False


def main():
    parser = argparse.ArgumentParser(
        description='从 Nacos 获取 Dubbo 服务并同步到 Higress Ingress',
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    parser.add_argument('-n', '--nacos', required=True, help='Nacos 服务器地址')
    parser.add_argument('-d', '--domain', required=True, help='Ingress 域名')
    parser.add_argument('-g', '--group', required=True, help='Nacos 服务分组')
    parser.add_argument('--namespace', default='', help='Nacos 命名空间 ID')
    parser.add_argument('--dry-run', action='store_true', help='只生成配置，不同步到 Higress')

    args = parser.parse_args()

    print(f"{Colors.BLUE}正在从 Nacos 获取 Dubbo 服务...{Colors.NC}")
    print(f"  Nacos: {args.nacos}")
    print(f"  Group: {args.group}")
    print()

    # 获取现有 Ingress 列表
    if not args.dry_run:
        print(f"\n{Colors.BLUE}获取现有 Ingress 列表...{Colors.NC}")
        existing_ingresses = get_existing_ingresses()
        existing_names = {item['metadata']['name'] for item in existing_ingresses}
        print(f"  {Colors.GREEN}✓ 发现 {len(existing_names)} 个现有 Ingress{Colors.NC}")
    else:
        existing_names = set()

    # 获取 Nacos 服务列表
    services = get_service_list(args.nacos, args.namespace, args.group)
    if not services:
        print(f"{Colors.YELLOW}⚠ 未找到任何服务{Colors.NC}")
        sys.exit(0)

    print(f"\n{Colors.GREEN}✓ 找到 {len(services)} 个服务{Colors.NC}")

    # 首先收集所有应用级服务的 api.md5 元数据
    print(f"\n{Colors.BLUE}收集应用级服务的 api.md5 元数据...{Colors.NC}")
    api_md5_map = collect_api_md5_from_services(args.nacos, services, args.group)
    print(f"  {Colors.GREEN}✓ 发现 {len(api_md5_map)} 个接口的 api.md5 元数据{Colors.NC}")
    for interface, md5 in api_md5_map.items():
        print(f"    • {interface}: {md5}")

    # 收集 Dubbo 接口信息（按接口去重）
    dubbo_services: Dict[str, Dict[str, Any]] = {}
    for service_name in services:
        # 跳过非 provider 服务
        if not service_name.startswith('providers:'):
            continue
            
        instances = get_service_instances(args.nacos, service_name, args.group)
        for instance in instances:
            dubbo_info = extract_dubbo_info(instance)
            if dubbo_info:
                key = f"{dubbo_info['interface']}:{dubbo_info['version']}"
                if key not in dubbo_services:
                    # 从应用级服务收集的 map 中查找 api.md5
                    api_md5 = api_md5_map.get(key, '')
                    
                    if not api_md5:
                        print(f"  {Colors.RED}✗{Colors.NC} {key} ({dubbo_info['application']}) - 缺少 api.md5 元数据，跳过")
                        continue

                    dubbo_services[key] = dubbo_info
                    print(f"  {Colors.GREEN}•{Colors.NC} {key} ({dubbo_info['application']}) - 元数据验证通过")

    if not dubbo_services:
        print(f"{Colors.YELLOW}⚠ 未找到有效的 Dubbo 接口（所有接口都缺少 API 元数据）{Colors.NC}")
        sys.exit(0)

    print(f"\n{Colors.GREEN}✓ 共找到 {len(dubbo_services)} 个有效的 Dubbo 接口{Colors.NC}")

    # 生成并同步 Ingress
    if args.dry_run:
        print(f"\n{Colors.BLUE}========== Ingress 配置预览 (dry-run) =========={Colors.NC}")
    else:
        print(f"\n{Colors.BLUE}生成并同步 Ingress...{Colors.NC}")

    created = 0
    skipped = 0
    failed = 0

    for svc in dubbo_services.values():
        ingress_name = build_ingress_name(svc)
        ingress = generate_ingress(svc, args.domain, args.group)

        if ingress_name in existing_names:
            print(f"  {Colors.YELLOW}• {ingress_name} 已存在，跳过{Colors.NC}")
            skipped += 1
            continue

        if args.dry_run:
            print(f"\n{Colors.GREEN}--- {ingress_name} ---{Colors.NC}")
            print(dict_to_yaml(ingress))
            created += 1
        else:
            if sync_ingress_to_higress(ingress):
                print(f"  {Colors.GREEN}✓ {ingress_name} 同步成功{Colors.NC}")
                created += 1
            else:
                failed += 1

    if args.dry_run:
        print(f"\n{Colors.BLUE}========== 配置预览结束 (未实际同步) =========={Colors.NC}")
        print(f"  {Colors.GREEN}✓ 共 {created} 个 Ingress 配置{Colors.NC}")
    else:
        print(f"\n{Colors.BLUE}========== 同步结果 =========={Colors.NC}")
        print(f"  {Colors.GREEN}✓ 成功: {created}{Colors.NC}")
        print(f"  {Colors.YELLOW}• 跳过: {skipped}{Colors.NC}")
        if failed > 0:
            print(f"  {Colors.RED}✗ 失败: {failed}{Colors.NC}")


if __name__ == '__main__':
    main()
