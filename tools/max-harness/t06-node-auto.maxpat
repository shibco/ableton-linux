{
	"patcher" : 	{
		"fileversion" : 1,
		"appversion" : 		{
			"major" : 9,
			"minor" : 1,
			"revision" : 4,
			"architecture" : "x64",
			"modernui" : 1
		},
		"classnamespace" : "box",
		"rect" : [ 160.0, 160.0, 620.0, 420.0 ],
		"boxes" : [ 			{
				"box" : 				{
					"id" : "obj-1",
					"maxclass" : "newobj",
					"text" : "loadbang",
					"numinlets" : 0,
					"numoutlets" : 1,
					"outlettype" : [ "bang" ],
					"patching_rect" : [ 30.0, 30.0, 60.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-2",
					"maxclass" : "message",
					"text" : "HARNESS t06 node loaded",
					"numinlets" : 2,
					"numoutlets" : 1,
					"outlettype" : [ "" ],
					"patching_rect" : [ 120.0, 30.0, 170.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-3",
					"maxclass" : "newobj",
					"text" : "print HARNESS",
					"numinlets" : 1,
					"numoutlets" : 0,
					"patching_rect" : [ 310.0, 30.0, 90.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-4",
					"maxclass" : "newobj",
					"text" : "node.script outlet-methods.js @autostart 1 @watch 0",
					"numinlets" : 1,
					"numoutlets" : 2,
					"outlettype" : [ "", "" ],
					"patching_rect" : [ 30.0, 160.0, 300.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-5",
					"maxclass" : "newobj",
					"text" : "delay 8000",
					"numinlets" : 2,
					"numoutlets" : 1,
					"outlettype" : [ "bang" ],
					"patching_rect" : [ 30.0, 70.0, 70.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-6",
					"maxclass" : "message",
					"text" : "example2",
					"numinlets" : 2,
					"numoutlets" : 1,
					"outlettype" : [ "" ],
					"patching_rect" : [ 30.0, 110.0, 70.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-7",
					"maxclass" : "newobj",
					"text" : "print NODEOUT",
					"numinlets" : 1,
					"numoutlets" : 0,
					"patching_rect" : [ 30.0, 210.0, 95.0, 22.0 ]
				}
			}
, 			{
				"box" : 				{
					"id" : "obj-8",
					"maxclass" : "newobj",
					"text" : "print NODESTATUS",
					"numinlets" : 1,
					"numoutlets" : 0,
					"patching_rect" : [ 160.0, 210.0, 110.0, 22.0 ]
				}
			}
 ],
		"lines" : [ 			{
				"patchline" : 				{
					"source" : [ "obj-1", 0 ],
					"destination" : [ "obj-2", 0 ]
				}
			}
, 			{
				"patchline" : 				{
					"source" : [ "obj-2", 0 ],
					"destination" : [ "obj-3", 0 ]
				}
			}
, 			{
				"patchline" : 				{
					"source" : [ "obj-1", 0 ],
					"destination" : [ "obj-5", 0 ]
				}
			}
, 			{
				"patchline" : 				{
					"source" : [ "obj-5", 0 ],
					"destination" : [ "obj-6", 0 ]
				}
			}
, 			{
				"patchline" : 				{
					"source" : [ "obj-6", 0 ],
					"destination" : [ "obj-4", 0 ]
				}
			}
, 			{
				"patchline" : 				{
					"source" : [ "obj-4", 0 ],
					"destination" : [ "obj-7", 0 ]
				}
			}
, 			{
				"patchline" : 				{
					"source" : [ "obj-4", 1 ],
					"destination" : [ "obj-8", 0 ]
				}
			}
 ]
	}
}
