<script lang="ts">
  import * as Table from "$lib/components/ui/table";
  import { Button } from "$lib/components/ui/button";
  import { formatRelativeTimestamp } from "$lib/utils";
  import { Code } from "lucide-svelte";
  import Beta from "$lib/components/Beta.svelte";

  export let transforms: Array<{
    id: string;
    name: string;
    type: string;
    snippet: string;
    insertedAt: string;
    updatedAt: string;
  }>;
</script>

<div class="container mx-auto py-10">
  <div class="flex justify-between items-center mb-4">
    <div class="flex items-center">
      <Code class="h-6 w-6 mr-2" />
      <h1 class="text-2xl font-bold">Transforms</h1>
      <div class="ml-2">
        <Beta size="lg" variant="subtle" />
      </div>
    </div>
    {#if transforms.length > 0}
      <a
        href="/transforms/new"
        data-phx-link="redirect"
        data-phx-link-state="push"
      >
        <Button>Create Transform</Button>
      </a>
    {/if}
  </div>

  {#if transforms.length === 0}
    <div class="w-full rounded-lg border-2 border-dashed border-gray-300">
      <div class="text-center py-12 w-1/2 mx-auto my-auto">
        <h2 class="text-xl font-semibold mb-4">No transforms found</h2>
        <p class="text-gray-600 mb-6">
          Transforms allow you to modify and restructure your data as it flows
          through your pipelines.
        </p>
        <a
          href="/transforms/new"
          data-phx-link="redirect"
          data-phx-link-state="push"
        >
          <Button>Create your first transform</Button>
        </a>
      </div>
    </div>
  {:else}
    <Table.Root>
      <Table.Header>
        <Table.Row>
          <Table.Head>Name</Table.Head>
          <Table.Head>Transform</Table.Head>
          <Table.Head>Created at</Table.Head>
          <Table.Head>Last updated</Table.Head>
        </Table.Row>
      </Table.Header>
      <Table.Body>
        {#each transforms as transform}
          <Table.Row
            class="cursor-pointer"
            on:click={() => {
              const url = `/transforms/${transform.id}`;
              window.history.pushState({}, "", url);
              dispatchEvent(new PopStateEvent("popstate"));
            }}
          >
            <Table.Cell>{transform.name}</Table.Cell>
            <Table.Cell>
              <div class="text-gray-600 bg-gray-50 p-2 rounded-md w-fit">
                <code>{transform.snippet}</code>
              </div>
            </Table.Cell>
            <Table.Cell>
              {formatRelativeTimestamp(transform.insertedAt)}
            </Table.Cell>
            <Table.Cell>
              {formatRelativeTimestamp(transform.updatedAt)}
            </Table.Cell>
          </Table.Row>
        {/each}
      </Table.Body>
    </Table.Root>
  {/if}
</div>
