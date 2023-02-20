import createGraph from "ngraph.graph"
import path from "ngraph.path"

class PathFinder {
  /** In the constructor, we’re creating an empty graph and fill it with linked nodes.
   * Each node is a token address and links have associated data, which is tick spacings–we’ll be able to extract this
   * information from paths found by A*. After initializing a graph, we instantiate A* algorithm implementation.
   * */
  constructor(pairs) {
    // Creating an empty graph
    this.graph = createGraph()

    pairs.forEach((pair) => {
      this.graph.addNode(pair.token0.address)
      this.graph.addNode(pair.token1.address)
      this.graph.addLink(pair.token0.address, pair.token1.address, pair.fee)
      this.graph.addLink(pair.token1.address, pair.token0.address, pair.fee)
    })

    this.finder = path.aStar(this.graph)
  }

  // we need to implement a function that will find a path between tokens and turn it into an array of token addresses and tick spacings:
  findPath(fromToken, toToken) {
    return this.finder
      .find(fromToken, toToken)
      .reduce((acc, node, i, orig) => {
        if (acc.length > 0) {
          acc.push(this.graph.getLink(orig[i - 1].id, node.id).data)
        }

        acc.push(node.id)

        return acc
      }, [])
      .reverse()
  }

  // this.finder.find(fromToken, toToken) returns a list of nodes and, unfortunately, doesn’t contain the information about edges between them (we store tick spacings in edges).
  // Thus, we’re calling this.graph.getLink(previousNode, currentNode) to find edges.
  // Now, whenever user changes input or output token, we can call pathFinder.findPath(token0, token1) to build a new path.
}

export default PathFinder
